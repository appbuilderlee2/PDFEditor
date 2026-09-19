// Phase 2 content-stream reader. Apple PDFKit/CoreGraphics do not expose a
// supported API for replacing an existing PDFPage content stream. Parsing and
// text extraction are available; mutation APIs fail explicitly and atomically.
import CoreGraphics
import Foundation
import PDFKit

@MainActor
public final class PDFContentStreamParser {
    public static let shared = PDFContentStreamParser()

    private init() {}

    public func parse(page: PDFPage) throws -> [PDFContentCommand] {
        guard let streamData = extractContentStream(page: page), !streamData.isEmpty else {
            throw PDFContentError.emptyContentStream
        }
        return tokenize(streamData)
    }

    /// Produces a diagnostic stream for the represented commands. Because
    /// PDFContentCommand intentionally omits many operands/operators, this is
    /// not suitable for replacing an existing page's content stream.
    public func encode(_ commands: [PDFContentCommand]) -> Data {
        let source = commands.map(commandToString).joined(separator: " ")
        return Data(source.utf8)
    }

    private func extractContentStream(page: PDFPage) -> Data? {
        guard let pageReference = page.pageRef else { return nil }
        guard let dictionary = pageReference.dictionary else { return nil }
        var contentsObject: CGPDFObjectRef?
        guard CGPDFDictionaryGetObject(dictionary, "Contents", &contentsObject),
              let contentsObject else {
            return nil
        }

        switch CGPDFObjectGetType(contentsObject) {
        case .stream:
            var stream: CGPDFStreamRef?
            guard CGPDFObjectGetValue(contentsObject, .stream, &stream), let stream else {
                return nil
            }
            return readStreamData(stream)

        case .array:
            var array: CGPDFArrayRef?
            guard CGPDFObjectGetValue(contentsObject, .array, &array), let array else {
                return nil
            }

            var combined = Data()
            for index in 0..<CGPDFArrayGetCount(array) {
                var element: CGPDFObjectRef?
                guard CGPDFArrayGetObject(array, index, &element),
                      let element,
                      CGPDFObjectGetType(element) == .stream else {
                    continue
                }
                var stream: CGPDFStreamRef?
                guard CGPDFObjectGetValue(element, .stream, &stream), let stream else {
                    continue
                }
                if !combined.isEmpty { combined.append(0x0A) }
                combined.append(readStreamData(stream))
            }
            return combined.isEmpty ? nil : combined

        default:
            return nil
        }
    }

    private func readStreamData(_ stream: CGPDFStreamRef) -> Data {
        var format: CGPDFDataFormat = .raw
        guard let data = CGPDFStreamCopyData(stream, &format) else { return Data() }
        return data as Data
    }

    private func tokenize(_ data: Data) -> [PDFContentCommand] {
        let tokens = lexicalTokens(in: data)
        var operands: [String] = []
        var commands: [PDFContentCommand] = []

        for token in tokens {
            switch token {
            case "BT":
                commands.append(.beginText)
                operands.removeAll(keepingCapacity: true)
            case "ET":
                commands.append(.endText)
                operands.removeAll(keepingCapacity: true)
            case "Tm":
                if numericSuffix(6, of: operands) != nil { commands.append(.textMatrix) }
                operands.removeAll(keepingCapacity: true)
            case "Td", "TD":
                if numericSuffix(2, of: operands) != nil { commands.append(.textPosition) }
                operands.removeAll(keepingCapacity: true)
            case "Tj":
                if let value = operands.last, value.hasPrefix("(") {
                    commands.append(.showText(decodeLiteralString(value)))
                }
                operands.removeAll(keepingCapacity: true)
            case "TJ":
                if let value = operands.last, value.hasPrefix("[") {
                    commands.append(.showText(strings(inArray: value).joined()))
                }
                operands.removeAll(keepingCapacity: true)
            case "re":
                if let values = numericSuffix(4, of: operands) {
                    commands.append(.rect(values[0], values[1], values[2], values[3]))
                }
                operands.removeAll(keepingCapacity: true)
            case "f", "F", "f*":
                commands.append(.fill)
                operands.removeAll(keepingCapacity: true)
            case "S", "s":
                commands.append(.stroke)
                operands.removeAll(keepingCapacity: true)
            case "w":
                if let width = numericSuffix(1, of: operands)?.first {
                    commands.append(.setLineWidth(width))
                }
                operands.removeAll(keepingCapacity: true)
            case "Tf":
                if operands.count >= 2,
                   let size = Double(operands[operands.count - 1]) {
                    let name = operands[operands.count - 2]
                        .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    commands.append(.setFont(name, CGFloat(size)))
                }
                operands.removeAll(keepingCapacity: true)
            case "q":
                commands.append(.saveState)
                operands.removeAll(keepingCapacity: true)
            case "Q":
                commands.append(.restoreState)
                operands.removeAll(keepingCapacity: true)
            default:
                if isLikelyOperator(token) {
                    // Discard operands belonging to operators outside the
                    // intentionally small command model.
                    operands.removeAll(keepingCapacity: true)
                } else {
                    operands.append(token)
                }
            }
        }

        return commands
    }

    private func numericSuffix(_ count: Int, of operands: [String]) -> [CGFloat]? {
        guard operands.count >= count else { return nil }
        let suffix = operands.suffix(count)
        let values = suffix.compactMap { value -> CGFloat? in
            guard let number = Double(value) else { return nil }
            return CGFloat(number)
        }
        return values.count == count ? values : nil
    }

    private func isLikelyOperator(_ token: String) -> Bool {
        guard let first = token.first else { return false }
        if first == "/" || first == "(" || first == "[" || first == "<" {
            return false
        }
        if Double(token) != nil || token == "true" || token == "false" || token == "null" {
            return false
        }
        return first.isLetter || token == "'" || token == "\""
    }

    /// Minimal lexical scanner that keeps literal strings and arrays intact,
    /// including whitespace inside them. It is intentionally not a full PDF
    /// grammar but avoids the previous operand/operator reversal.
    private func lexicalTokens(in data: Data) -> [String] {
        let bytes = Array(data)
        var result: [String] = []
        var index = 0

        while index < bytes.count {
            if isWhitespace(bytes[index]) {
                index += 1
                continue
            }
            if bytes[index] == 0x25 { // % comment
                while index < bytes.count, bytes[index] != 0x0A, bytes[index] != 0x0D {
                    index += 1
                }
                continue
            }

            let start = index
            if bytes[index] == 0x28 { // literal string
                index = endOfLiteral(in: bytes, startingAt: index)
            } else if bytes[index] == 0x5B { // array
                index = endOfArray(in: bytes, startingAt: index)
            } else {
                while index < bytes.count, !isWhitespace(bytes[index]) {
                    index += 1
                }
            }
            result.append(String(decoding: bytes[start..<index], as: UTF8.self))
        }
        return result
    }

    private func endOfLiteral(in bytes: [UInt8], startingAt start: Int) -> Int {
        var index = start + 1
        var depth = 1
        var escaped = false
        while index < bytes.count, depth > 0 {
            let byte = bytes[index]
            if escaped {
                escaped = false
            } else if byte == 0x5C {
                escaped = true
            } else if byte == 0x28 {
                depth += 1
            } else if byte == 0x29 {
                depth -= 1
            }
            index += 1
        }
        return index
    }

    private func endOfArray(in bytes: [UInt8], startingAt start: Int) -> Int {
        var index = start + 1
        var depth = 1
        while index < bytes.count, depth > 0 {
            if bytes[index] == 0x28 {
                index = endOfLiteral(in: bytes, startingAt: index)
                continue
            }
            if bytes[index] == 0x5B { depth += 1 }
            if bytes[index] == 0x5D { depth -= 1 }
            index += 1
        }
        return index
    }

    private func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x00 || byte == 0x09 || byte == 0x0A || byte == 0x0C ||
            byte == 0x0D || byte == 0x20
    }

    private func strings(inArray array: String) -> [String] {
        guard array.hasPrefix("["), array.hasSuffix("]") else { return [] }
        let body = array.dropFirst().dropLast()
        return lexicalTokens(in: Data(body.utf8)).compactMap { token in
            token.hasPrefix("(") ? decodeLiteralString(token) : nil
        }
    }

    private func decodeLiteralString(_ token: String) -> String {
        guard token.hasPrefix("("), token.hasSuffix(")") else { return token }
        let body = token.dropFirst().dropLast()
        var result = ""
        var escaped = false
        for character in body {
            if escaped {
                switch character {
                case "n": result.append("\n")
                case "r": result.append("\r")
                case "t": result.append("\t")
                default: result.append(character)
                }
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else {
                result.append(character)
            }
        }
        if escaped { result.append("\\") }
        return result
    }

    private func commandToString(_ command: PDFContentCommand) -> String {
        switch command {
        case .beginText: return "BT"
        case .endText: return "ET"
        case .textMatrix: return "1 0 0 1 0 0 Tm"
        case .textPosition: return "0 0 Td"
        case .showText(let string): return "(\(escapePDFString(string))) Tj"
        case .rect(let x, let y, let width, let height):
            return "\(x) \(y) \(width) \(height) re"
        case .fill: return "f"
        case .stroke: return "S"
        case .setLineWidth(let width): return "\(width) w"
        case .setFont(let font, let size): return "/\(font) \(size) Tf"
        case .saveState: return "q"
        case .restoreState: return "Q"
        }
    }

    private func escapePDFString(_ string: String) -> String {
        string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "(", with: "\\(")
            .replacingOccurrences(of: ")", with: "\\)")
            .replacingOccurrences(of: "\n", with: "\\n")
    }
}

@MainActor
public final class PDFContentEngine {
    public static let shared = PDFContentEngine()

    private init() {}

    public func insertText(
        document: PDFDocumentWrapper,
        pageIndex: Int,
        text: String,
        at point: CGPoint,
        font: String = "Helvetica",
        fontSize: CGFloat = 12
    ) throws {
        try validatePage(in: document, at: pageIndex)
        throw PDFContentError.unsupportedContentWriteback
    }

    public func replaceText(
        document: PDFDocumentWrapper,
        pageIndex: Int,
        oldText: String,
        newText: String
    ) throws {
        let page = try validatePage(in: document, at: pageIndex)
        guard !oldText.isEmpty, page.string?.contains(oldText) == true else {
            throw PDFContentError.textNotFound
        }
        guard let url = document.url else {
            throw PDFContentError.unsupportedContentWriteback
        }

        do {
            try MinimalPDFTextRewriter.replaceUniqueLiteralText(
                in: url,
                oldText: oldText,
                newText: newText
            )

            // The writer edits the real PDF bytes on disk. Reload immediately
            // so a later Save cannot overwrite the new content with the stale
            // pre-edit PDFDocument object.
            guard let reloaded = PDFDocument(url: url) else {
                throw PDFContentError.unsupportedContentWriteback
            }
            document.pdfDocument = reloaded
            document.isModified = false
        } catch let error as MinimalPDFTextRewriter.RewriteError {
            switch error {
            case .targetNotFound:
                throw PDFContentError.textNotFound
            case .ambiguousTarget:
                throw PDFContentError.notYetImplemented(
                    "同一文字對應多個 Tj/TJ text object；需要 object/byte-range identity 才可安全修改"
                )
            case .unsupportedEncoding:
                throw PDFContentError.notYetImplemented(
                    "目前只能寫入原 PDF encoding / ToUnicode CMap 可表示的文字"
                )
            case .unsupportedFilter:
                throw PDFContentError.notYetImplemented(
                    "目前只支援未壓縮或 FlateDecode content stream"
                )
            case .unsupportedPDF, .decompressionFailed, .compressionFailed,
                 .unreadableFile, .writeFailed:
                throw PDFContentError.unsupportedContentWriteback
            }
        }
    }

    public func deleteText(
        document: PDFDocumentWrapper,
        pageIndex: Int,
        text: String
    ) throws {
        try validatePage(in: document, at: pageIndex)
        throw PDFContentError.unsupportedContentWriteback
    }

    public func addHighlight(
        document: PDFDocumentWrapper,
        pageIndex: Int,
        rect: CGRect,
        color: CGColor = CGColor(red: 1, green: 1, blue: 0, alpha: 0.3)
    ) throws {
        try validatePage(in: document, at: pageIndex)
        throw PDFContentError.unsupportedContentWriteback
    }

    public func addShape(
        document: PDFDocumentWrapper,
        pageIndex: Int,
        rect: CGRect,
        type: AnnotationType,
        strokeColor: CGColor = CGColor(red: 0, green: 0, blue: 0, alpha: 1),
        fillColor: CGColor? = nil,
        lineWidth: CGFloat = 1
    ) throws {
        try validatePage(in: document, at: pageIndex)
        throw PDFContentError.unsupportedContentWriteback
    }

    public func addFreehand(
        document: PDFDocumentWrapper,
        pageIndex: Int,
        points: [CGPoint],
        strokeColor: CGColor = CGColor(red: 1, green: 0, blue: 0, alpha: 1),
        lineWidth: CGFloat = 2
    ) throws {
        guard points.count >= 2 else { throw PDFContentError.invalidPath }
        try validatePage(in: document, at: pageIndex)
        throw PDFContentError.unsupportedContentWriteback
    }

    public func extractText(from document: PDFDocumentWrapper, pageIndex: Int) throws -> String {
        let page = try validatePage(in: document, at: pageIndex)
        return page.string ?? ""
    }

    public func hasModifications(_ document: PDFDocumentWrapper) -> Bool {
        document.isModified
    }

    private func validatePage(in wrapper: PDFDocumentWrapper, at index: Int) throws -> PDFPage {
        guard let document = wrapper.pdfDocument else { throw PDFContentError.noDocument }
        guard index >= 0, index < document.pageCount else {
            throw PDFContentError.invalidPageIndex
        }
        guard let page = document.page(at: index) else { throw PDFContentError.pageNotFound }
        return page
    }
}

public enum PDFContentError: Error, LocalizedError {
    case noDocument
    case invalidPageIndex
    case pageNotFound
    case emptyContentStream
    case textNotFound
    case invalidPath
    case unsupportedContentWriteback
    case notYetImplemented(String)

    public var errorDescription: String? {
        switch self {
        case .noDocument: return "未載入 PDF 文檔"
        case .invalidPageIndex: return "頁面索引超出範圍"
        case .pageNotFound: return "頁面不存在"
        case .emptyContentStream: return "內容流為空"
        case .textNotFound: return "找不到指定文字"
        case .invalidPath: return "路徑點數不足"
        case .unsupportedContentWriteback:
            return "Apple PDFKit/CoreGraphics 不支援原地改寫既有頁面的內容流"
        case .notYetImplemented(let message): return "尚未實作: \(message)"
        }
    }
}

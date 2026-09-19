import Compression
import Foundation

/// Conservative content-stream writer for the first existing-text editing
/// milestones. It performs real PDF incremental updates: the original bytes
/// remain intact and a newer revision of the target stream object is appended
/// with a fresh xref/trailer section.
///
/// Supported now:
/// - literal-string `Tj`
/// - uncompressed streams
/// - `/FlateDecode` streams
/// - variable-length printable-ASCII replacements
///
/// Deliberately not supported yet: `TJ` arrays, hex strings, encrypted PDFs,
/// object streams, CID/font re-encoding, or multiple ambiguous occurrences.
enum MinimalPDFTextRewriter {
    enum RewriteError: Error, Equatable {
        case unsupportedEncoding
        case unsupportedPDF
        case unsupportedFilter
        case decompressionFailed
        case compressionFailed
        case targetNotFound
        case ambiguousTarget
        case unreadableFile
        case writeFailed
    }

    private struct StreamObject {
        let objectNumber: Int
        let generation: Int
        let dictionary: String
        let encodedData: Data
        let isFlateEncoded: Bool
    }

    private struct Candidate {
        let stream: StreamObject
        let rewrittenDecodedData: Data
    }

    static func replaceUniqueLiteralText(
        in fileURL: URL,
        oldText: String,
        newText: String
    ) throws {
        guard fileURL.isFileURL else { throw RewriteError.unreadableFile }
        guard !oldText.isEmpty,
              oldText.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value <= 0x7E }),
              newText.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value <= 0x7E }) else {
            throw RewriteError.unsupportedEncoding
        }

        guard let originalData = try? Data(contentsOf: fileURL),
              !originalData.isEmpty else {
            throw RewriteError.unreadableFile
        }

        let headerText = String(decoding: originalData.prefix(min(originalData.count, 4096)), as: UTF8.self)
        guard headerText.contains("%PDF-") else { throw RewriteError.unsupportedPDF }

        let latin1 = String(data: originalData, encoding: .isoLatin1) ?? ""
        if latin1.contains("/Encrypt") {
            throw RewriteError.unsupportedPDF
        }

        let streams = try parseStreamObjects(in: originalData)
        var candidates: [Candidate] = []

        for stream in streams {
            let decoded: Data
            if stream.isFlateEncoded {
                decoded = try zlibDecode(stream.encodedData)
            } else {
                decoded = stream.encodedData
            }

            guard let rewritten = try rewriteUniqueLiteralTj(
                in: decoded,
                oldText: oldText,
                newText: newText
            ) else {
                continue
            }

            candidates.append(Candidate(stream: stream, rewrittenDecodedData: rewritten))
        }

        guard !candidates.isEmpty else { throw RewriteError.targetNotFound }
        guard candidates.count == 1 else { throw RewriteError.ambiguousTarget }

        let candidate = candidates[0]
        let newEncodedData = candidate.stream.isFlateEncoded
            ? try zlibEncode(candidate.rewrittenDecodedData)
            : candidate.rewrittenDecodedData

        let previousXref = try lastStartXref(in: originalData)
        let trailer = try trailerInfo(in: originalData)
        let rewrittenDictionary = replacingLength(
            in: candidate.stream.dictionary,
            with: newEncodedData.count
        )

        let updatedData = makeIncrementalRevision(
            originalData: originalData,
            objectNumber: candidate.stream.objectNumber,
            generation: candidate.stream.generation,
            dictionary: rewrittenDictionary,
            streamData: newEncodedData,
            previousXref: previousXref,
            trailerSize: max(trailer.size, candidate.stream.objectNumber + 1),
            rootObjectNumber: trailer.rootObjectNumber,
            rootGeneration: trailer.rootGeneration
        )

        do {
            try updatedData.write(to: fileURL, options: .atomic)
        } catch {
            throw RewriteError.writeFailed
        }
    }

    // MARK: - Stream parsing

    private static func parseStreamObjects(in data: Data) throws -> [StreamObject] {
        let bytes = [UInt8](data)
        let marker = Array(" obj".utf8)
        let streamMarker = Array("stream".utf8)
        let endStreamMarker = Array("endstream".utf8)
        var results: [StreamObject] = []
        var searchIndex = 0

        while let objMarker = find(marker, in: bytes, from: searchIndex) {
            guard let lineStart = previousLineStart(in: bytes, before: objMarker),
                  let header = asciiString(bytes[lineStart..<objMarker]),
                  let (objectNumber, generation) = parseObjectHeader(header) else {
                searchIndex = objMarker + marker.count
                continue
            }

            let afterHeader = objMarker + marker.count
            guard let streamPos = find(streamMarker, in: bytes, from: afterHeader),
                  let endObjPos = find(Array("endobj".utf8), in: bytes, from: afterHeader),
                  streamPos < endObjPos else {
                searchIndex = afterHeader
                continue
            }

            let dictionaryBytes = bytes[afterHeader..<streamPos]
            guard let dictionary = String(bytes: dictionaryBytes, encoding: .isoLatin1),
                  dictionary.contains("<<"),
                  dictionary.contains(">>"),
                  dictionary.contains("/Length") else {
                searchIndex = afterHeader
                continue
            }

            if dictionary.contains("/Filter"),
               !dictionary.contains("/FlateDecode") {
                searchIndex = afterHeader
                continue
            }

            var streamDataStart = streamPos + streamMarker.count
            if streamDataStart < bytes.count, bytes[streamDataStart] == 0x0D {
                streamDataStart += 1
                if streamDataStart < bytes.count, bytes[streamDataStart] == 0x0A {
                    streamDataStart += 1
                }
            } else if streamDataStart < bytes.count, bytes[streamDataStart] == 0x0A {
                streamDataStart += 1
            }

            guard let declaredLength = directStreamLength(in: dictionary),
                  declaredLength >= 0,
                  streamDataStart + declaredLength <= bytes.count else {
                // Indirect /Length objects are intentionally deferred until a
                // proper object resolver is introduced.
                searchIndex = afterHeader
                continue
            }

            let streamDataEnd = streamDataStart + declaredLength
            guard streamDataEnd <= endObjPos,
                  let endStreamPos = find(endStreamMarker, in: bytes, from: streamDataEnd),
                  endStreamPos <= endObjPos else {
                searchIndex = afterHeader
                continue
            }

            results.append(
                StreamObject(
                    objectNumber: objectNumber,
                    generation: generation,
                    dictionary: dictionary.trimmingCharacters(in: .whitespacesAndNewlines),
                    encodedData: Data(bytes[streamDataStart..<streamDataEnd]),
                    isFlateEncoded: dictionary.contains("/FlateDecode")
                )
            )

            searchIndex = endObjPos + 6
        }

        return results
    }

    private static func directStreamLength(in dictionary: String) -> Int? {
        let indirectPattern = #"/Length\s+\d+\s+\d+\s+R"#
        if let indirectRegex = try? NSRegularExpression(pattern: indirectPattern),
           indirectRegex.firstMatch(
               in: dictionary,
               range: NSRange(dictionary.startIndex..<dictionary.endIndex, in: dictionary)
           ) != nil {
            return nil
        }

        let pattern = #"/Length\s+(\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(dictionary.startIndex..<dictionary.endIndex, in: dictionary)
        guard let match = regex.firstMatch(in: dictionary, range: range),
              let valueRange = Range(match.range(at: 1), in: dictionary) else {
            return nil
        }
        return Int(dictionary[valueRange])
    }

    private static func parseObjectHeader(_ text: String) -> (Int, Int)? {
        let pieces = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isWhitespace })
        guard pieces.count >= 2,
              let objectNumber = Int(pieces[pieces.count - 2]),
              let generation = Int(pieces[pieces.count - 1]) else {
            return nil
        }
        return (objectNumber, generation)
    }

    // MARK: - Literal Tj replacement

    /// Returns nil if this decoded content stream does not contain the target.
    /// Throws ambiguousTarget if the target appears more than once in this
    /// stream, because object identity is not implemented yet.
    private static func rewriteUniqueLiteralTj(
        in decodedData: Data,
        oldText: String,
        newText: String
    ) throws -> Data? {
        guard var source = String(data: decodedData, encoding: .isoLatin1) else {
            throw RewriteError.unsupportedEncoding
        }

        let pattern = #"\((?:\\.|[^\\)])*\)\s*Tj"#
        let regex = try NSRegularExpression(pattern: pattern)
        let fullRange = NSRange(source.startIndex..<source.endIndex, in: source)

        struct Match {
            let bodyRange: Range<String.Index>
            let replacementBody: String
        }

        var matches: [Match] = []

        for result in regex.matches(in: source, range: fullRange) {
            guard let wholeRange = Range(result.range, in: source),
                  let open = source[wholeRange].firstIndex(of: "("),
                  let close = source[wholeRange].lastIndex(of: ")") else {
                continue
            }

            let bodyRange = source.index(after: open)..<close
            let encodedBody = String(source[bodyRange])
            let decodedBody = decodeLiteralBody(encodedBody)

            var searchStart = decodedBody.startIndex
            var occurrenceCount = 0
            var onlyOccurrence: Range<String.Index>?

            while searchStart <= decodedBody.endIndex,
                  let occurrence = decodedBody.range(of: oldText, range: searchStart..<decodedBody.endIndex) {
                occurrenceCount += 1
                onlyOccurrence = occurrence
                searchStart = occurrence.upperBound
            }

            guard occurrenceCount > 0 else { continue }
            guard occurrenceCount == 1, let occurrence = onlyOccurrence else {
                throw RewriteError.ambiguousTarget
            }

            var replaced = decodedBody
            replaced.replaceSubrange(occurrence, with: newText)
            matches.append(
                Match(
                    bodyRange: bodyRange,
                    replacementBody: encodeLiteralBody(replaced)
                )
            )
        }

        guard !matches.isEmpty else { return nil }
        guard matches.count == 1 else { throw RewriteError.ambiguousTarget }

        let match = matches[0]
        source.replaceSubrange(match.bodyRange, with: match.replacementBody)

        guard let rewritten = source.data(using: .isoLatin1) else {
            throw RewriteError.unsupportedEncoding
        }
        return rewritten
    }

    // MARK: - Incremental PDF update

    private static func makeIncrementalRevision(
        originalData: Data,
        objectNumber: Int,
        generation: Int,
        dictionary: String,
        streamData: Data,
        previousXref: Int,
        trailerSize: Int,
        rootObjectNumber: Int,
        rootGeneration: Int
    ) -> Data {
        var output = originalData
        if output.last != 0x0A { output.append(0x0A) }

        let objectOffset = output.count
        appendASCII("\(objectNumber) \(generation) obj\n", to: &output)
        appendASCII(dictionary, to: &output)
        appendASCII("\nstream\n", to: &output)
        output.append(streamData)
        appendASCII("\nendstream\nendobj\n", to: &output)

        let xrefOffset = output.count
        appendASCII("xref\n\(objectNumber) 1\n", to: &output)
        appendASCII(String(format: "%010d %05d n \n", objectOffset, generation), to: &output)
        appendASCII(
            "trailer\n<< /Size \(trailerSize) /Root \(rootObjectNumber) \(rootGeneration) R /Prev \(previousXref) >>\n",
            to: &output
        )
        appendASCII("startxref\n\(xrefOffset)\n%%EOF\n", to: &output)
        return output
    }

    private static func replacingLength(in dictionary: String, with length: Int) -> String {
        let pattern = #"/Length\s+\d+"#
        if let regex = try? NSRegularExpression(pattern: pattern),
           regex.firstMatch(
               in: dictionary,
               range: NSRange(dictionary.startIndex..<dictionary.endIndex, in: dictionary)
           ) != nil {
            return regex.stringByReplacingMatches(
                in: dictionary,
                range: NSRange(dictionary.startIndex..<dictionary.endIndex, in: dictionary),
                withTemplate: "/Length \(length)"
            )
        }

        guard let close = dictionary.range(of: ">>", options: .backwards) else {
            return dictionary
        }
        var value = dictionary
        value.insert(contentsOf: " /Length \(length) ", at: close.lowerBound)
        return value
    }

    private static func lastStartXref(in data: Data) throws -> Int {
        guard let text = String(data: data, encoding: .isoLatin1) else {
            throw RewriteError.unsupportedPDF
        }
        let pattern = #"startxref\s+(\d+)"#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.matches(in: text, range: range).last,
              let valueRange = Range(match.range(at: 1), in: text),
              let value = Int(text[valueRange]) else {
            throw RewriteError.unsupportedPDF
        }
        return value
    }

    private static func trailerInfo(
        in data: Data
    ) throws -> (size: Int, rootObjectNumber: Int, rootGeneration: Int) {
        guard let text = String(data: data, encoding: .isoLatin1) else {
            throw RewriteError.unsupportedPDF
        }

        let rootRegex = try NSRegularExpression(pattern: #"/Root\s+(\d+)\s+(\d+)\s+R"#)
        let sizeRegex = try NSRegularExpression(pattern: #"/Size\s+(\d+)"#)
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)

        guard let rootMatch = rootRegex.matches(in: text, range: fullRange).last,
              let rootNumberRange = Range(rootMatch.range(at: 1), in: text),
              let rootGenerationRange = Range(rootMatch.range(at: 2), in: text),
              let rootObjectNumber = Int(text[rootNumberRange]),
              let rootGeneration = Int(text[rootGenerationRange]),
              let sizeMatch = sizeRegex.matches(in: text, range: fullRange).last,
              let sizeRange = Range(sizeMatch.range(at: 1), in: text),
              let size = Int(text[sizeRange]) else {
            throw RewriteError.unsupportedPDF
        }

        return (size, rootObjectNumber, rootGeneration)
    }

    // MARK: - FlateDecode

    private static func zlibDecode(_ input: Data) throws -> Data {
        guard !input.isEmpty else { return Data() }

        // Apple's Compression framework names this algorithm ZLIB, but its
        // buffer API consumes raw RFC1951 DEFLATE. PDF /FlateDecode streams are
        // RFC1950 zlib streams, so strip the wrapper before decoding.
        let rawDeflate: Data
        let expectedAdler: UInt32?

        if let wrapped = splitZlibStream(input) {
            rawDeflate = wrapped.payload
            expectedAdler = wrapped.adler32
        } else {
            // Be permissive with non-conforming PDFs that contain raw DEFLATE.
            rawDeflate = input
            expectedAdler = nil
        }

        var capacity = max(rawDeflate.count * 4, 4096)

        while capacity <= 64 * 1024 * 1024 {
            var output = Data(count: capacity)
            let decodedCount = output.withUnsafeMutableBytes { destination in
                rawDeflate.withUnsafeBytes { source in
                    compression_decode_buffer(
                        destination.bindMemory(to: UInt8.self).baseAddress!,
                        capacity,
                        source.bindMemory(to: UInt8.self).baseAddress!,
                        rawDeflate.count,
                        nil,
                        COMPRESSION_ZLIB
                    )
                }
            }

            if decodedCount > 0 {
                output.count = decodedCount
                if let expectedAdler, adler32(output) != expectedAdler {
                    throw RewriteError.decompressionFailed
                }
                return output
            }
            capacity *= 2
        }

        throw RewriteError.decompressionFailed
    }

    private static func zlibEncode(_ input: Data) throws -> Data {
        guard !input.isEmpty else { return Data() }
        var capacity = max(input.count + 1024, input.count * 2)

        while capacity <= 64 * 1024 * 1024 {
            var raw = Data(count: capacity)
            let encodedCount = raw.withUnsafeMutableBytes { destination in
                input.withUnsafeBytes { source in
                    compression_encode_buffer(
                        destination.bindMemory(to: UInt8.self).baseAddress!,
                        capacity,
                        source.bindMemory(to: UInt8.self).baseAddress!,
                        input.count,
                        nil,
                        COMPRESSION_ZLIB
                    )
                }
            }

            if encodedCount > 0 {
                raw.count = encodedCount

                // RFC1950 zlib wrapper. 0x78 0x9C declares DEFLATE with a 32K
                // window and a default compression level. FLEVEL is advisory.
                var wrapped = Data([0x78, 0x9C])
                wrapped.append(raw)
                let checksum = adler32(input)
                wrapped.append(UInt8((checksum >> 24) & 0xFF))
                wrapped.append(UInt8((checksum >> 16) & 0xFF))
                wrapped.append(UInt8((checksum >> 8) & 0xFF))
                wrapped.append(UInt8(checksum & 0xFF))
                return wrapped
            }
            capacity *= 2
        }

        throw RewriteError.compressionFailed
    }

    private static func splitZlibStream(
        _ input: Data
    ) -> (payload: Data, adler32: UInt32)? {
        guard input.count >= 6 else { return nil }
        let bytes = [UInt8](input)
        let cmf = bytes[0]
        let flg = bytes[1]

        guard cmf & 0x0F == 8,
              ((Int(cmf) << 8) + Int(flg)) % 31 == 0,
              flg & 0x20 == 0 else {
            return nil
        }

        let checksumStart = bytes.count - 4
        let checksum =
            (UInt32(bytes[checksumStart]) << 24) |
            (UInt32(bytes[checksumStart + 1]) << 16) |
            (UInt32(bytes[checksumStart + 2]) << 8) |
            UInt32(bytes[checksumStart + 3])

        return (
            Data(bytes[2..<checksumStart]),
            checksum
        )
    }

    private static func adler32(_ data: Data) -> UInt32 {
        let modulus: UInt32 = 65_521
        var a: UInt32 = 1
        var b: UInt32 = 0

        for byte in data {
            a = (a + UInt32(byte)) % modulus
            b = (b + a) % modulus
        }

        return (b << 16) | a
    }

    // MARK: - Helpers

    private static func appendASCII(_ string: String, to data: inout Data) {
        data.append(contentsOf: string.utf8)
    }

    private static func asciiString(_ bytes: ArraySlice<UInt8>) -> String? {
        String(bytes: bytes, encoding: .ascii)
    }

    private static func previousLineStart(in bytes: [UInt8], before index: Int) -> Int? {
        var cursor = index
        while cursor > 0 {
            let byte = bytes[cursor - 1]
            if byte == 0x0A || byte == 0x0D { break }
            cursor -= 1
        }
        return cursor
    }

    private static func find(_ needle: [UInt8], in haystack: [UInt8], from start: Int) -> Int? {
        guard !needle.isEmpty, start <= haystack.count - needle.count else { return nil }
        var index = max(0, start)
        while index <= haystack.count - needle.count {
            if haystack[index..<(index + needle.count)].elementsEqual(needle) {
                return index
            }
            index += 1
        }
        return nil
    }

    private static func decodeLiteralBody(_ body: String) -> String {
        var result = ""
        var index = body.startIndex

        while index < body.endIndex {
            let character = body[index]
            if character != "\\" {
                result.append(character)
                index = body.index(after: index)
                continue
            }

            let next = body.index(after: index)
            guard next < body.endIndex else {
                result.append("\\")
                break
            }

            switch body[next] {
            case "n": result.append("\n")
            case "r": result.append("\r")
            case "t": result.append("\t")
            case "b": result.append("\u{0008}")
            case "f": result.append("\u{000C}")
            case "(", ")", "\\":
                result.append(body[next])
            default:
                result.append(body[next])
            }

            index = body.index(after: next)
        }

        return result
    }

    private static func encodeLiteralBody(_ body: String) -> String {
        var result = ""
        for character in body {
            switch character {
            case "\\": result += "\\\\"
            case "(": result += "\\("
            case ")": result += "\\)"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            default: result.append(character)
            }
        }
        return result
    }
}

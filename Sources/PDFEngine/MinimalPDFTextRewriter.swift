import Compression
import Foundation

/// Conservative content-stream writer for the first existing-text editing
/// milestones. It performs real PDF incremental updates: the original bytes
/// remain intact and a newer revision of the target stream object is appended
/// with a fresh xref/trailer section.
///
/// Supported now:
/// - literal-string `Tj`
/// - literal-string `TJ` arrays, including text split across segments
/// - hex-string `Tj` for byte-oriented Latin/ASCII text
/// - uncompressed streams
/// - `/FlateDecode` streams
/// - variable-length printable-ASCII replacements
/// - direct and indirect stream `/Length` entries
/// - Type0 `/Identity-H` hex text using resource-specific `/ToUnicode` CMaps
///
/// Deliberately not supported yet: encrypted PDFs,
/// object streams, CID/font re-encoding, or multiple ambiguous occurrences.
enum MinimalPDFTextRewriter {
    struct TextObjectID: Hashable {
        let streamObjectNumber: Int
        let streamGeneration: Int
        let operatorStartOffset: Int
        let operatorEndOffset: Int
    }

    enum TextOperatorKind: String, Equatable {
        case literalTj
        case hexTj
        case tjArray
    }

    struct TextObject: Identifiable, Equatable {
        let id: TextObjectID
        let text: String
        let fontResourceName: String?
        let kind: TextOperatorKind
    }

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
    private struct ToUnicodeCMap {
        let forward: [Data: String]
        let reverse: [String: Data]
        let codeLength: Int

        func decode(_ data: Data) -> String? {
            guard codeLength > 0, data.count % codeLength == 0 else { return nil }
            var result = ""
            var offset = 0
            while offset < data.count {
                let chunk = data.subdata(in: offset..<(offset + codeLength))
                guard let value = forward[chunk] else { return nil }
                result += value
                offset += codeLength
            }
            return result
        }

        func encode(_ string: String) -> Data? {
            var result = Data()
            for character in string {
                guard let code = reverse[String(character)] else { return nil }
                result.append(code)
            }
            return result
        }
    }


    static func replaceUniqueLiteralText(
        in fileURL: URL,
        oldText: String,
        newText: String
    ) throws {
        guard fileURL.isFileURL else { throw RewriteError.unreadableFile }
        guard !oldText.isEmpty else {
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
        let toUnicodeCMaps = try type0ToUnicodeCMapsByResourceName(
            in: originalData,
            streams: streams
        )
        let toUnicodeCMapsByContentStream = try type0ToUnicodeCMapsByContentStream(
            in: originalData,
            streams: streams
        )
        var candidates: [Candidate] = []

        for stream in latestStreamObjects(streams) {
            let decoded: Data
            if stream.isFlateEncoded {
                decoded = try zlibDecode(stream.encodedData)
            } else {
                decoded = stream.encodedData
            }

            guard let rewritten = try rewriteUniqueTextOperator(
                in: decoded,
                oldText: oldText,
                newText: newText,
                toUnicodeCMaps:
                    toUnicodeCMapsByContentStream[streamKey(stream)] ??
                    toUnicodeCMaps
            ) else {
                continue
            }

            candidates.append(Candidate(stream: stream, rewrittenDecodedData: rewritten))
        }

        guard !candidates.isEmpty else { throw RewriteError.targetNotFound }
        guard candidates.count == 1 else { throw RewriteError.ambiguousTarget }

        let candidate = candidates[0]
        try writeIncrementalStreamRevision(
            originalData: originalData,
            stream: candidate.stream,
            rewrittenDecodedData: candidate.rewrittenDecodedData,
            fileURL: fileURL
        )
    }

    static func textObjects(in fileURL: URL) throws -> [TextObject] {
        let context = try loadContext(from: fileURL)
        var objects: [TextObject] = []

        for stream in latestStreamObjects(context.streams) {
            let decoded = stream.isFlateEncoded
                ? try zlibDecode(stream.encodedData)
                : stream.encodedData

            guard let source = String(data: decoded, encoding: .isoLatin1) else {
                continue
            }

            let regex = try textOperatorRegex()
            let fullRange = NSRange(source.startIndex..<source.endIndex, in: source)

            for result in regex.matches(in: source, range: fullRange) {
                guard let wholeRange = Range(result.range, in: source) else { continue }
                let whole = String(source[wholeRange])
                let fontResourceName = currentFontResourceName(
                    in: source,
                    before: wholeRange.lowerBound
                )
                let activeMaps = cMaps(for: stream, context: context)
                let cmap =
                    fontResourceName.flatMap { activeMaps[$0] } ??
                    activeMaps["__single_type0_fallback__"]

                guard let parsed = try parseVisibleTextOperator(
                    whole,
                    toUnicodeCMap: cmap
                ) else {
                    continue
                }

                let startOffset = latin1ByteCount(source[..<wholeRange.lowerBound])
                let endOffset = startOffset + latin1ByteCount(source[wholeRange])

                objects.append(
                    TextObject(
                        id: TextObjectID(
                            streamObjectNumber: stream.objectNumber,
                            streamGeneration: stream.generation,
                            operatorStartOffset: startOffset,
                            operatorEndOffset: endOffset
                        ),
                        text: parsed.text,
                        fontResourceName: fontResourceName,
                        kind: parsed.kind
                    )
                )
            }
        }

        return objects
    }

    static func replaceText(
        in fileURL: URL,
        target: TextObjectID,
        oldText: String,
        newText: String
    ) throws {
        guard !oldText.isEmpty else { throw RewriteError.unsupportedEncoding }
        let context = try loadContext(from: fileURL)

        guard let stream = latestStreamObjects(context.streams).first(where: {
            $0.objectNumber == target.streamObjectNumber &&
            $0.generation == target.streamGeneration
        }) else {
            throw RewriteError.targetNotFound
        }

        let decoded = stream.isFlateEncoded
            ? try zlibDecode(stream.encodedData)
            : stream.encodedData

        guard var source = String(data: decoded, encoding: .isoLatin1),
              let wholeRange = latin1StringRange(
                  in: source,
                  startOffset: target.operatorStartOffset,
                  endOffset: target.operatorEndOffset
              ) else {
            throw RewriteError.targetNotFound
        }

        let whole = String(source[wholeRange])
        let fontResourceName = currentFontResourceName(
            in: source,
            before: wholeRange.lowerBound
        )
        let activeMaps = cMaps(for: stream, context: context)
        let cmap =
            fontResourceName.flatMap { activeMaps[$0] } ??
            activeMaps["__single_type0_fallback__"]

        guard let replacement = try rewriteSpecificTextOperator(
            whole,
            oldText: oldText,
            newText: newText,
            toUnicodeCMap: cmap
        ) else {
            throw RewriteError.targetNotFound
        }

        source.replaceSubrange(wholeRange, with: replacement)
        guard let rewrittenDecoded = source.data(using: .isoLatin1) else {
            throw RewriteError.unsupportedEncoding
        }

        try writeIncrementalStreamRevision(
            originalData: context.originalData,
            stream: stream,
            rewrittenDecodedData: rewrittenDecoded,
            fileURL: fileURL
        )
    }

    private struct RewriteContext {
        let originalData: Data
        let streams: [StreamObject]
        let toUnicodeCMaps: [String: ToUnicodeCMap]
        let toUnicodeCMapsByContentStream: [String: [String: ToUnicodeCMap]]
    }

    private static func loadContext(from fileURL: URL) throws -> RewriteContext {
        guard fileURL.isFileURL,
              let originalData = try? Data(contentsOf: fileURL),
              !originalData.isEmpty else {
            throw RewriteError.unreadableFile
        }

        let headerText = String(
            decoding: originalData.prefix(min(originalData.count, 4096)),
            as: UTF8.self
        )
        guard headerText.contains("%PDF-") else {
            throw RewriteError.unsupportedPDF
        }

        let latin1 = String(data: originalData, encoding: .isoLatin1) ?? ""
        guard !latin1.contains("/Encrypt") else {
            throw RewriteError.unsupportedPDF
        }

        let streams = try parseStreamObjects(in: originalData)
        let maps = try type0ToUnicodeCMapsByResourceName(
            in: originalData,
            streams: streams
        )
        let streamMaps = try type0ToUnicodeCMapsByContentStream(
            in: originalData,
            streams: streams
        )
        return RewriteContext(
            originalData: originalData,
            streams: streams,
            toUnicodeCMaps: maps,
            toUnicodeCMapsByContentStream: streamMaps
        )
    }

    private static func latestStreamObjects(_ streams: [StreamObject]) -> [StreamObject] {
        var latestIndex: [String: Int] = [:]
        for (index, stream) in streams.enumerated() {
            latestIndex["\(stream.objectNumber):\(stream.generation)"] = index
        }

        return streams.enumerated().compactMap { index, stream in
            let key = "\(stream.objectNumber):\(stream.generation)"
            return latestIndex[key] == index ? stream : nil
        }
    }

    private static func streamKey(
        objectNumber: Int,
        generation: Int
    ) -> String {
        "\(objectNumber):\(generation)"
    }

    private static func streamKey(_ stream: StreamObject) -> String {
        streamKey(
            objectNumber: stream.objectNumber,
            generation: stream.generation
        )
    }

    private static func cMaps(
        for stream: StreamObject,
        context: RewriteContext
    ) -> [String: ToUnicodeCMap] {
        context.toUnicodeCMapsByContentStream[streamKey(stream)] ??
        context.toUnicodeCMaps
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

            guard let declaredLength = streamLength(in: dictionary, pdfBytes: bytes),
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

    private static func streamLength(
        in dictionary: String,
        pdfBytes: [UInt8]
    ) -> Int? {
        let indirectPattern = #"/Length\s+(\d+)\s+(\d+)\s+R"#
        if let regex = try? NSRegularExpression(pattern: indirectPattern),
           let match = regex.firstMatch(
               in: dictionary,
               range: NSRange(dictionary.startIndex..<dictionary.endIndex, in: dictionary)
           ),
           let objectRange = Range(match.range(at: 1), in: dictionary),
           let generationRange = Range(match.range(at: 2), in: dictionary),
           let objectNumber = Int(dictionary[objectRange]),
           let generation = Int(dictionary[generationRange]) {
            return resolveIndirectInteger(
                objectNumber: objectNumber,
                generation: generation,
                in: pdfBytes
            )
        }

        let directPattern = #"/Length\s+(\d+)"#
        guard let regex = try? NSRegularExpression(pattern: directPattern) else { return nil }
        let range = NSRange(dictionary.startIndex..<dictionary.endIndex, in: dictionary)
        guard let match = regex.firstMatch(in: dictionary, range: range),
              let valueRange = Range(match.range(at: 1), in: dictionary) else {
            return nil
        }
        return Int(dictionary[valueRange])
    }

    private static func resolveIndirectInteger(
        objectNumber: Int,
        generation: Int,
        in bytes: [UInt8]
    ) -> Int? {
        let header = Array("\(objectNumber) \(generation) obj".utf8)
        let endMarker = Array("endobj".utf8)
        var searchIndex = 0
        var latestValue: Int?

        while let headerIndex = find(header, in: bytes, from: searchIndex) {
            // Require a token/line boundary before the object header so object
            // numbers embedded in stream bytes are not mistaken for objects.
            if headerIndex > 0 {
                let previous = bytes[headerIndex - 1]
                if previous != 0x0A && previous != 0x0D && previous != 0x20 {
                    searchIndex = headerIndex + header.count
                    continue
                }
            }

            let bodyStart = headerIndex + header.count
            guard let endIndex = find(endMarker, in: bytes, from: bodyStart) else { break }
            let body = String(
                bytes: bytes[bodyStart..<endIndex],
                encoding: .ascii
            )?.trimmingCharacters(in: .whitespacesAndNewlines)

            if let body,
               let value = Int(body.split(whereSeparator: { $0.isWhitespace }).first ?? "") {
                latestValue = value
            }

            searchIndex = endIndex + endMarker.count
        }

        // In an incremental PDF the latest revision wins.
        return latestValue
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

    // MARK: - Type0 / ToUnicode

    /// Resolve Type0 font objects to their ToUnicode streams, then connect
    /// those font objects to page resource names such as /F1 and /F2.
    ///
    /// If the same resource name points to different Type0 fonts in different
    /// resource dictionaries, that name is treated as ambiguous and omitted.
    private static func type0ToUnicodeCMapsByResourceName(
        in pdfData: Data,
        streams: [StreamObject]
    ) throws -> [String: ToUnicodeCMap] {
        guard let source = String(data: pdfData, encoding: .isoLatin1) else {
            return [:]
        }

        let type0Pattern = #"(?s)(\d+)\s+(\d+)\s+obj\s*<<(?:(?!endobj).)*?/Subtype\s*/Type0(?:(?!endobj).)*?/ToUnicode\s+(\d+)\s+(\d+)\s+R(?:(?!endobj).)*?endobj"#
        let type0Regex = try NSRegularExpression(pattern: type0Pattern)
        let fullRange = NSRange(source.startIndex..<source.endIndex, in: source)

        var cmapByFontObject: [Int: ToUnicodeCMap] = [:]

        for match in type0Regex.matches(in: source, range: fullRange) {
            guard let fontObjectRange = Range(match.range(at: 1), in: source),
                  let cmapObjectRange = Range(match.range(at: 3), in: source),
                  let cmapGenerationRange = Range(match.range(at: 4), in: source),
                  let fontObject = Int(source[fontObjectRange]),
                  let cmapObject = Int(source[cmapObjectRange]),
                  let cmapGeneration = Int(source[cmapGenerationRange]),
                  let stream = streams.last(where: {
                      $0.objectNumber == cmapObject &&
                      $0.generation == cmapGeneration
                  }) else {
                continue
            }

            let decoded = stream.isFlateEncoded
                ? try zlibDecode(stream.encodedData)
                : stream.encodedData

            guard let cmapText = String(data: decoded, encoding: .ascii),
                  let cmap = parseToUnicodeCMap(cmapText) else {
                continue
            }
            cmapByFontObject[fontObject] = cmap
        }

        guard !cmapByFontObject.isEmpty else { return [:] }

        let fontDictionaryRegex = try NSRegularExpression(
            pattern: #"(?s)/Font\s*<<(.+?)>>"#
        )
        let entryRegex = try NSRegularExpression(
            pattern: #"/([^\s/<>\[\]()]+)\s+(\d+)\s+(\d+)\s+R"#
        )

        var resolved: [String: ToUnicodeCMap] = [:]
        var resolvedObject: [String: Int] = [:]
        var ambiguous: Set<String> = []

        for dictMatch in fontDictionaryRegex.matches(in: source, range: fullRange) {
            guard let dictRange = Range(dictMatch.range(at: 1), in: source) else {
                continue
            }
            let dictionary = String(source[dictRange])
            let range = NSRange(
                dictionary.startIndex..<dictionary.endIndex,
                in: dictionary
            )

            for entry in entryRegex.matches(in: dictionary, range: range) {
                guard let nameRange = Range(entry.range(at: 1), in: dictionary),
                      let objectRange = Range(entry.range(at: 2), in: dictionary),
                      let objectNumber = Int(dictionary[objectRange]),
                      let cmap = cmapByFontObject[objectNumber] else {
                    continue
                }

                let name = String(dictionary[nameRange])
                if let previous = resolvedObject[name],
                   previous != objectNumber {
                    ambiguous.insert(name)
                    resolved.removeValue(forKey: name)
                    resolvedObject.removeValue(forKey: name)
                    continue
                }

                guard !ambiguous.contains(name) else { continue }
                resolved[name] = cmap
                resolvedObject[name] = objectNumber
            }
        }

        // Some generated PDFs expose a single Type0 font but have unusual
        // resource formatting. Keep a controlled fallback under a sentinel key.
        if resolved.isEmpty, cmapByFontObject.count == 1,
           let only = cmapByFontObject.values.first {
            resolved["__single_type0_fallback__"] = only
        }

        return resolved
    }

    /// Resolve a page's font resources to the page's own content stream.
    /// This allows /F1 on page A and /F1 on page B to refer to different
    /// Type0 fonts without becoming globally ambiguous.
    private static func type0ToUnicodeCMapsByContentStream(
        in pdfData: Data,
        streams: [StreamObject]
    ) throws -> [String: [String: ToUnicodeCMap]] {
        guard let source = String(data: pdfData, encoding: .isoLatin1) else {
            return [:]
        }

        let fullRange = NSRange(source.startIndex..<source.endIndex, in: source)

        // Build Type0 font object -> ToUnicode CMap.
        let type0Regex = try NSRegularExpression(
            pattern: #"(?s)(\d+)\s+(\d+)\s+obj\s*<<(?:(?!endobj).)*?/Subtype\s*/Type0(?:(?!endobj).)*?/ToUnicode\s+(\d+)\s+(\d+)\s+R(?:(?!endobj).)*?endobj"#
        )
        var cmapByFontObject: [Int: ToUnicodeCMap] = [:]

        for match in type0Regex.matches(in: source, range: fullRange) {
            guard let fontRange = Range(match.range(at: 1), in: source),
                  let cmapRange = Range(match.range(at: 3), in: source),
                  let cmapGenRange = Range(match.range(at: 4), in: source),
                  let fontObject = Int(source[fontRange]),
                  let cmapObject = Int(source[cmapRange]),
                  let cmapGeneration = Int(source[cmapGenRange]),
                  let stream = streams.last(where: {
                      $0.objectNumber == cmapObject &&
                      $0.generation == cmapGeneration
                  }) else {
                continue
            }

            let decoded = stream.isFlateEncoded
                ? try zlibDecode(stream.encodedData)
                : stream.encodedData

            guard let cmapText = String(data: decoded, encoding: .ascii),
                  let cmap = parseToUnicodeCMap(cmapText) else {
                continue
            }
            cmapByFontObject[fontObject] = cmap
        }

        guard !cmapByFontObject.isEmpty else { return [:] }

        let pageRegex = try NSRegularExpression(
            pattern: #"(?s)(\d+)\s+(\d+)\s+obj\s*(<<(?:(?!endobj).)*?/Type\s*/Page\b(?:(?!endobj).)*?>>)\s*endobj"#
        )
        let fontDictionaryRegex = try NSRegularExpression(
            pattern: #"(?s)/Font\s*<<(.+?)>>"#
        )
        let fontEntryRegex = try NSRegularExpression(
            pattern: #"/([^\s/<>\[\]()]+)\s+(\d+)\s+(\d+)\s+R"#
        )
        let indirectResourcesRegex = try NSRegularExpression(
            pattern: #"/Resources\s+(\d+)\s+(\d+)\s+R"#
        )
        let indirectFontDictionaryRegex = try NSRegularExpression(
            pattern: #"/Font\s+(\d+)\s+(\d+)\s+R"#
        )
        let contentsArrayRegex = try NSRegularExpression(
            pattern: #"(?s)/Contents\s*\[(.*?)\]"#
        )
        let contentsDirectRegex = try NSRegularExpression(
            pattern: #"/Contents\s+(\d+)\s+(\d+)\s+R"#
        )
        let referenceRegex = try NSRegularExpression(
            pattern: #"(\d+)\s+(\d+)\s+R"#
        )

        func indirectObjectBody(_ objectNumber: Int, _ generation: Int) -> String? {
            let escaped = #"(?s)(?:^|[\r\n])"# +
                String(objectNumber) + #"\s+"# +
                String(generation) + #"\s+obj\s*(.*?)\s*endobj"#
            guard let regex = try? NSRegularExpression(pattern: escaped),
                  let match = regex.matches(in: source, range: fullRange).last,
                  let bodyRange = Range(match.range(at: 1), in: source) else {
                return nil
            }
            return String(source[bodyRange])
        }

        func fontObjects(in resourceText: String) -> [String: Int] {
            func parseEntries(_ dictionary: String) -> [String: Int] {
                let dictionaryRange = NSRange(
                    dictionary.startIndex..<dictionary.endIndex,
                    in: dictionary
                )
                var result: [String: Int] = [:]

                for entry in fontEntryRegex.matches(
                    in: dictionary,
                    range: dictionaryRange
                ) {
                    guard let nameRange = Range(
                        entry.range(at: 1),
                        in: dictionary
                    ),
                    let objectRange = Range(
                        entry.range(at: 2),
                        in: dictionary
                    ),
                    let objectNumber = Int(dictionary[objectRange]),
                    cmapByFontObject[objectNumber] != nil else {
                        continue
                    }
                    result[String(dictionary[nameRange])] = objectNumber
                }
                return result
            }

            let resourceRange = NSRange(
                resourceText.startIndex..<resourceText.endIndex,
                in: resourceText
            )

            // Inline form: /Font << /F1 4 0 R >>
            if let fontMatch = fontDictionaryRegex.firstMatch(
                in: resourceText,
                range: resourceRange
            ),
            let dictRange = Range(fontMatch.range(at: 1), in: resourceText) {
                return parseEntries(String(resourceText[dictRange]))
            }

            // Indirect form: /Font 10 0 R, where object 10 is the font
            // resource dictionary itself.
            if let fontMatch = indirectFontDictionaryRegex.firstMatch(
                in: resourceText,
                range: resourceRange
            ),
            let objectRange = Range(fontMatch.range(at: 1), in: resourceText),
            let generationRange = Range(fontMatch.range(at: 2), in: resourceText),
            let objectNumber = Int(resourceText[objectRange]),
            let generation = Int(resourceText[generationRange]),
            let indirect = indirectObjectBody(objectNumber, generation) {
                return parseEntries(indirect)
            }

            return [:]
        }

        func contentStreamKeys(in pageBody: String) -> [String] {
            let pageRange = NSRange(
                pageBody.startIndex..<pageBody.endIndex,
                in: pageBody
            )
            var keys: [String] = []

            if let arrayMatch = contentsArrayRegex.firstMatch(
                in: pageBody,
                range: pageRange
            ),
            let arrayRange = Range(arrayMatch.range(at: 1), in: pageBody) {
                let arrayBody = String(pageBody[arrayRange])
                let arrayNSRange = NSRange(
                    arrayBody.startIndex..<arrayBody.endIndex,
                    in: arrayBody
                )
                for reference in referenceRegex.matches(
                    in: arrayBody,
                    range: arrayNSRange
                ) {
                    guard let objectRange = Range(
                        reference.range(at: 1),
                        in: arrayBody
                    ),
                    let generationRange = Range(
                        reference.range(at: 2),
                        in: arrayBody
                    ),
                    let objectNumber = Int(arrayBody[objectRange]),
                    let generation = Int(arrayBody[generationRange]) else {
                        continue
                    }
                    keys.append(
                        streamKey(
                            objectNumber: objectNumber,
                            generation: generation
                        )
                    )
                }
                return keys
            }

            if let directMatch = contentsDirectRegex.firstMatch(
                in: pageBody,
                range: pageRange
            ),
            let objectRange = Range(directMatch.range(at: 1), in: pageBody),
            let generationRange = Range(directMatch.range(at: 2), in: pageBody),
            let objectNumber = Int(pageBody[objectRange]),
            let generation = Int(pageBody[generationRange]) {
                keys.append(
                    streamKey(
                        objectNumber: objectNumber,
                        generation: generation
                    )
                )
            }
            return keys
        }

        var result: [String: [String: ToUnicodeCMap]] = [:]
        var assignedFontObjects: [String: [String: Int]] = [:]

        for pageMatch in pageRegex.matches(in: source, range: fullRange) {
            guard let pageRange = Range(pageMatch.range(at: 3), in: source) else {
                continue
            }
            let pageBody = String(source[pageRange])
            let pageNSRange = NSRange(
                pageBody.startIndex..<pageBody.endIndex,
                in: pageBody
            )

            var resourceText = pageBody
            if let resourceMatch = indirectResourcesRegex.firstMatch(
                in: pageBody,
                range: pageNSRange
            ),
            let objectRange = Range(resourceMatch.range(at: 1), in: pageBody),
            let generationRange = Range(resourceMatch.range(at: 2), in: pageBody),
            let objectNumber = Int(pageBody[objectRange]),
            let generation = Int(pageBody[generationRange]),
            let indirect = indirectObjectBody(objectNumber, generation) {
                resourceText = indirect
            }

            let pageFonts = fontObjects(in: resourceText)
            guard !pageFonts.isEmpty else { continue }

            for contentKey in contentStreamKeys(in: pageBody) {
                var fontAssignments = assignedFontObjects[contentKey] ?? [:]
                var maps = result[contentKey] ?? [:]

                for (resourceName, fontObject) in pageFonts {
                    if let previous = fontAssignments[resourceName],
                       previous != fontObject {
                        // Reused stream under conflicting resources: do not
                        // guess which font map applies to that resource name.
                        fontAssignments.removeValue(forKey: resourceName)
                        maps.removeValue(forKey: resourceName)
                        continue
                    }

                    guard let cmap = cmapByFontObject[fontObject] else { continue }
                    fontAssignments[resourceName] = fontObject
                    maps[resourceName] = cmap
                }

                assignedFontObjects[contentKey] = fontAssignments
                result[contentKey] = maps
            }
        }

        return result
    }

    private static func parseToUnicodeCMap(_ cmap: String) -> ToUnicodeCMap? {
        var forward: [Data: String] = [:]

        parseBFCharSections(cmap, into: &forward)
        parseBFRangeSections(cmap, into: &forward)

        guard !forward.isEmpty else { return nil }
        let lengths = Set(forward.keys.map(\.count))
        guard lengths.count == 1, let codeLength = lengths.first, codeLength > 0 else {
            return nil
        }

        var reverse: [String: Data] = [:]
        for (code, unicode) in forward where reverse[unicode] == nil {
            reverse[unicode] = code
        }

        return ToUnicodeCMap(
            forward: forward,
            reverse: reverse,
            codeLength: codeLength
        )
    }

    private static func parseBFCharSections(
        _ cmap: String,
        into forward: inout [Data: String]
    ) {
        guard let sectionRegex = try? NSRegularExpression(
            pattern: #"(?s)\d+\s+beginbfchar(.*?)endbfchar"#
        ),
        let pairRegex = try? NSRegularExpression(
            pattern: #"<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>"#
        ) else {
            return
        }

        let fullRange = NSRange(cmap.startIndex..<cmap.endIndex, in: cmap)
        for sectionMatch in sectionRegex.matches(in: cmap, range: fullRange) {
            guard let sectionRange = Range(sectionMatch.range(at: 1), in: cmap) else {
                continue
            }
            let section = String(cmap[sectionRange])
            let range = NSRange(section.startIndex..<section.endIndex, in: section)

            for match in pairRegex.matches(in: section, range: range) {
                guard let srcRange = Range(match.range(at: 1), in: section),
                      let dstRange = Range(match.range(at: 2), in: section),
                      let src = decodeHexString(String(section[srcRange])),
                      let dstData = decodeHexString(String(section[dstRange])),
                      let unicode = String(data: dstData, encoding: .utf16BigEndian),
                      !unicode.isEmpty else {
                    continue
                }
                forward[src] = unicode
            }
        }
    }

    private static func parseBFRangeSections(
        _ cmap: String,
        into forward: inout [Data: String]
    ) {
        guard let sectionRegex = try? NSRegularExpression(
            pattern: #"(?s)\d+\s+beginbfrange(.*?)endbfrange"#
        ),
        let sequentialRegex = try? NSRegularExpression(
            pattern: #"<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>"#
        ),
        let arrayRegex = try? NSRegularExpression(
            pattern: #"(?s)<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>\s*\[(.*?)\]"#
        ),
        let destinationRegex = try? NSRegularExpression(
            pattern: #"<([0-9A-Fa-f]+)>"#
        ) else {
            return
        }

        let fullRange = NSRange(cmap.startIndex..<cmap.endIndex, in: cmap)
        for sectionMatch in sectionRegex.matches(in: cmap, range: fullRange) {
            guard let sectionRange = Range(sectionMatch.range(at: 1), in: cmap) else {
                continue
            }
            let section = String(cmap[sectionRange])
            let sectionNSRange = NSRange(section.startIndex..<section.endIndex, in: section)

            // Sequential form:
            // <0001> <0003> <4F60>
            // maps each successive source code to successive UTF-16BE values.
            for match in sequentialRegex.matches(in: section, range: sectionNSRange) {
                guard let startRange = Range(match.range(at: 1), in: section),
                      let endRange = Range(match.range(at: 2), in: section),
                      let dstRange = Range(match.range(at: 3), in: section),
                      let sourceStart = decodeHexString(String(section[startRange])),
                      let sourceEnd = decodeHexString(String(section[endRange])),
                      let destinationStart = decodeHexString(String(section[dstRange])),
                      sourceStart.count == sourceEnd.count,
                      let startValue = integerValue(sourceStart),
                      let endValue = integerValue(sourceEnd),
                      endValue >= startValue else {
                    continue
                }

                let count = endValue - startValue
                guard count <= 65_535 else { continue }

                for delta in 0...count {
                    guard let sourceCode = dataValue(
                        startValue + delta,
                        byteCount: sourceStart.count
                    ),
                    let destination = incrementUTF16BE(
                        destinationStart,
                        by: delta
                    ),
                    let unicode = String(
                        data: destination,
                        encoding: .utf16BigEndian
                    ),
                    !unicode.isEmpty else {
                        continue
                    }
                    forward[sourceCode] = unicode
                }
            }

            // Array form:
            // <0001> <0003> [<4F60> <597D> <60A8>]
            // maps each source code to the corresponding explicit Unicode
            // destination. This is common in generated/subset-font PDFs.
            for match in arrayRegex.matches(in: section, range: sectionNSRange) {
                guard let startRange = Range(match.range(at: 1), in: section),
                      let endRange = Range(match.range(at: 2), in: section),
                      let arrayBodyRange = Range(match.range(at: 3), in: section),
                      let sourceStart = decodeHexString(String(section[startRange])),
                      let sourceEnd = decodeHexString(String(section[endRange])),
                      sourceStart.count == sourceEnd.count,
                      let startValue = integerValue(sourceStart),
                      let endValue = integerValue(sourceEnd),
                      endValue >= startValue else {
                    continue
                }

                let arrayBody = String(section[arrayBodyRange])
                let arrayNSRange = NSRange(
                    arrayBody.startIndex..<arrayBody.endIndex,
                    in: arrayBody
                )
                let destinations = destinationRegex.matches(
                    in: arrayBody,
                    range: arrayNSRange
                )

                let expectedCount = endValue - startValue + 1
                guard expectedCount <= 65_536,
                      destinations.count == Int(expectedCount) else {
                    continue
                }

                for (index, destinationMatch) in destinations.enumerated() {
                    guard let destinationRange = Range(
                        destinationMatch.range(at: 1),
                        in: arrayBody
                    ),
                    let destinationData = decodeHexString(
                        String(arrayBody[destinationRange])
                    ),
                    let unicode = String(
                        data: destinationData,
                        encoding: .utf16BigEndian
                    ),
                    !unicode.isEmpty,
                    let sourceCode = dataValue(
                        startValue + UInt64(index),
                        byteCount: sourceStart.count
                    ) else {
                        continue
                    }
                    forward[sourceCode] = unicode
                }
            }
        }
    }

    private static func integerValue(_ data: Data) -> UInt64? {
        guard data.count <= 8 else { return nil }
        var value: UInt64 = 0
        for byte in data {
            value = (value << 8) | UInt64(byte)
        }
        return value
    }

    private static func dataValue(_ value: UInt64, byteCount: Int) -> Data? {
        guard byteCount > 0, byteCount <= 8 else { return nil }
        let maxValue: UInt64 = byteCount == 8
            ? UInt64.max
            : (UInt64(1) << UInt64(byteCount * 8)) - 1
        guard value <= maxValue else { return nil }

        var bytes = [UInt8](repeating: 0, count: byteCount)
        var working = value
        for index in stride(from: byteCount - 1, through: 0, by: -1) {
            bytes[index] = UInt8(working & 0xFF)
            working >>= 8
        }
        return Data(bytes)
    }

    private static func incrementUTF16BE(
        _ data: Data,
        by delta: UInt64
    ) -> Data? {
        guard data.count == 2 || data.count == 4,
              let value = integerValue(data),
              value <= UInt64.max - delta else {
            return nil
        }
        return dataValue(value + delta, byteCount: data.count)
    }

    // MARK: - Tj / TJ replacement

    /// Rewrites exactly one matching text-show operator in the decoded stream.
    /// Both literal-string Tj and literal-string TJ arrays are supported.
    private static func rewriteUniqueTextOperator(
        in decodedData: Data,
        oldText: String,
        newText: String,
        toUnicodeCMaps: [String: ToUnicodeCMap]
    ) throws -> Data? {
        guard var source = String(data: decodedData, encoding: .isoLatin1) else {
            throw RewriteError.unsupportedEncoding
        }

        let regex = try textOperatorRegex()
        let fullRange = NSRange(source.startIndex..<source.endIndex, in: source)

        struct Match {
            let wholeRange: Range<String.Index>
            let replacement: String
        }

        var matches: [Match] = []

        for result in regex.matches(in: source, range: fullRange) {
            guard let wholeRange = Range(result.range, in: source) else { continue }
            let whole = String(source[wholeRange])

            let visibleText: String
            let replacementOperator: String?
            let trimmed = whole.trimmingCharacters(in: .whitespacesAndNewlines)
            let currentFont = currentFontResourceName(
                in: source,
                before: wholeRange.lowerBound
            )
            let toUnicodeCMap =
                currentFont.flatMap { toUnicodeCMaps[$0] } ??
                toUnicodeCMaps["__single_type0_fallback__"]

            if trimmed.hasPrefix("<") && trimmed.hasSuffix("Tj") {
                guard let parsed = try rewriteHexTjOperator(
                    whole,
                    oldText: oldText,
                    newText: newText,
                    toUnicodeCMap: toUnicodeCMap
                ) else { continue }
                visibleText = parsed.visibleText
                replacementOperator = parsed.replacement
            } else if trimmed.hasSuffix("Tj") {
                guard let parsed = rewriteLiteralTjOperator(
                    whole,
                    oldText: oldText,
                    newText: newText
                ) else { continue }
                visibleText = parsed.visibleText
                replacementOperator = parsed.replacement
            } else {
                guard let parsed = try rewriteTJArrayOperator(
                    whole,
                    oldText: oldText,
                    newText: newText,
                    toUnicodeCMap: toUnicodeCMap
                ) else { continue }
                visibleText = parsed.visibleText
                replacementOperator = parsed.replacement
            }

            guard visibleText.contains(oldText), let replacementOperator else { continue }
            matches.append(Match(wholeRange: wholeRange, replacement: replacementOperator))
        }

        guard !matches.isEmpty else { return nil }
        guard matches.count == 1 else { throw RewriteError.ambiguousTarget }

        let match = matches[0]
        source.replaceSubrange(match.wholeRange, with: match.replacement)

        guard let rewritten = source.data(using: .isoLatin1) else {
            throw RewriteError.unsupportedEncoding
        }
        return rewritten
    }

    private static func textOperatorRegex() throws -> NSRegularExpression {
        try NSRegularExpression(
            pattern: #"(\((?:\\.|[^\\)])*\)\s*Tj)|(<[0-9A-Fa-f\s]+>\s*Tj)|(\[(?:\\.|[^\]])*\]\s*TJ)"#
        )
    }

    private static func parseVisibleTextOperator(
        _ whole: String,
        toUnicodeCMap: ToUnicodeCMap?
    ) throws -> (text: String, kind: TextOperatorKind)? {
        let trimmed = whole.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.hasPrefix("<") && trimmed.hasSuffix("Tj") {
            guard let open = whole.firstIndex(of: "<"),
                  let close = whole.firstIndex(of: ">"),
                  open < close else {
                return nil
            }

            let rawHex = String(whole[whole.index(after: open)..<close])
                .filter { !$0.isWhitespace }
            guard let data = decodeHexString(rawHex) else {
                throw RewriteError.unsupportedEncoding
            }

            if let toUnicodeCMap,
               let mapped = toUnicodeCMap.decode(data) {
                return (mapped, .hexTj)
            }

            guard let latin = String(data: data, encoding: .isoLatin1) else {
                throw RewriteError.unsupportedEncoding
            }
            return (latin, .hexTj)
        }

        if trimmed.hasSuffix("Tj") {
            guard let open = whole.firstIndex(of: "("),
                  let close = whole.lastIndex(of: ")"),
                  open < close else {
                return nil
            }
            let body = String(whole[whole.index(after: open)..<close])
            return (decodeLiteralBody(body), .literalTj)
        }

        if trimmed.hasSuffix("TJ"),
           let open = whole.firstIndex(of: "["),
           let close = whole.lastIndex(of: "]"),
           open < close {
            let body = String(whole[whole.index(after: open)..<close])
            let tokens = parseTJTokens(body)
            let text = try tokens.map {
                try visibleText(for: $0, toUnicodeCMap: toUnicodeCMap)
            }.joined()
            return (text, .tjArray)
        }

        return nil
    }

    private static func rewriteSpecificTextOperator(
        _ whole: String,
        oldText: String,
        newText: String,
        toUnicodeCMap: ToUnicodeCMap?
    ) throws -> String? {
        guard let parsed = try parseVisibleTextOperator(
            whole,
            toUnicodeCMap: toUnicodeCMap
        ) else {
            return nil
        }

        let occurrences = ranges(of: oldText, in: parsed.text)
        guard !occurrences.isEmpty else { return nil }
        guard occurrences.count == 1 else {
            throw RewriteError.ambiguousTarget
        }

        switch parsed.kind {
        case .literalTj:
            return rewriteLiteralTjOperator(
                whole,
                oldText: oldText,
                newText: newText
            )?.replacement
        case .hexTj:
            return try rewriteHexTjOperator(
                whole,
                oldText: oldText,
                newText: newText,
                toUnicodeCMap: toUnicodeCMap
            )?.replacement
        case .tjArray:
            return try rewriteTJArrayOperator(
                whole,
                oldText: oldText,
                newText: newText,
                toUnicodeCMap: toUnicodeCMap
            )?.replacement
        }
    }

    private static func latin1ByteCount<S: StringProtocol>(_ text: S) -> Int {
        text.unicodeScalars.count
    }

    private static func latin1StringRange(
        in source: String,
        startOffset: Int,
        endOffset: Int
    ) -> Range<String.Index>? {
        guard startOffset >= 0,
              endOffset >= startOffset else {
            return nil
        }

        let scalars = source.unicodeScalars
        guard endOffset <= scalars.count else { return nil }

        let start = scalars.index(scalars.startIndex, offsetBy: startOffset)
        let end = scalars.index(scalars.startIndex, offsetBy: endOffset)
        return start..<end
    }

    private static func currentFontResourceName(
        in source: String,
        before index: String.Index
    ) -> String? {
        let prefix = String(source[..<index])
        guard let regex = try? NSRegularExpression(
            pattern: #"/([^\s/<>\[\]()]+)\s+[-+]?(?:\d+(?:\.\d*)?|\.\d+)\s+Tf"#
        ) else {
            return nil
        }

        let range = NSRange(prefix.startIndex..<prefix.endIndex, in: prefix)
        guard let match = regex.matches(in: prefix, range: range).last,
              let nameRange = Range(match.range(at: 1), in: prefix) else {
            return nil
        }
        return String(prefix[nameRange])
    }

    private static func rewriteLiteralTjOperator(
        _ whole: String,
        oldText: String,
        newText: String
    ) -> (visibleText: String, replacement: String?)? {
        guard let open = whole.firstIndex(of: "("),
              let close = whole.lastIndex(of: ")"),
              open < close else {
            return nil
        }

        let body = String(whole[whole.index(after: open)..<close])
        let decoded = decodeLiteralBody(body)
        let occurrences = ranges(of: oldText, in: decoded)
        guard !occurrences.isEmpty else {
            return (decoded, nil)
        }
        guard occurrences.count == 1, let occurrence = occurrences.first else {
            return (decoded, nil)
        }

        var replaced = decoded
        replaced.replaceSubrange(occurrence, with: newText)
        return (decoded, "(\(encodeLiteralBody(replaced))) Tj")
    }

    private static func rewriteHexTjOperator(
        _ whole: String,
        oldText: String,
        newText: String,
        toUnicodeCMap: ToUnicodeCMap?
    ) throws -> (visibleText: String, replacement: String?)? {
        guard let open = whole.firstIndex(of: "<"),
              let close = whole.firstIndex(of: ">"),
              open < close else {
            return nil
        }

        let rawHex = String(whole[whole.index(after: open)..<close])
            .filter { !$0.isWhitespace }
        guard let decodedData = decodeHexString(rawHex) else {
            throw RewriteError.unsupportedEncoding
        }

        let decoded: String
        if let toUnicodeCMap,
           let mapped = toUnicodeCMap.decode(decodedData) {
            decoded = mapped
        } else {
            // This hex operator may belong to a simple byte font even when
            // another Type0 font exists in the document.
            guard let latin = String(data: decodedData, encoding: .isoLatin1) else {
                throw RewriteError.unsupportedEncoding
            }
            decoded = latin
        }

        let occurrences = ranges(of: oldText, in: decoded)
        guard !occurrences.isEmpty else {
            return (decoded, nil)
        }
        guard occurrences.count == 1, let occurrence = occurrences.first else {
            throw RewriteError.ambiguousTarget
        }

        var replaced = decoded
        replaced.replaceSubrange(occurrence, with: newText)

        let bytes: Data
        if let toUnicodeCMap,
           toUnicodeCMap.decode(decodedData) != nil {
            guard let mapped = toUnicodeCMap.encode(replaced) else {
                throw RewriteError.unsupportedEncoding
            }
            bytes = mapped
        } else {
            guard let latin = replaced.data(using: .isoLatin1) else {
                throw RewriteError.unsupportedEncoding
            }
            bytes = latin
        }

        return (decoded, "<\(encodeHexString(bytes))> Tj")
    }

    private static func decodeHexString(_ hex: String) -> Data? {
        guard !hex.isEmpty else { return Data() }
        var normalized = hex
        if normalized.count % 2 != 0 {
            normalized.append("0")
        }

        var data = Data()
        var index = normalized.startIndex
        while index < normalized.endIndex {
            let next = normalized.index(index, offsetBy: 2)
            let pair = normalized[index..<next]
            guard let byte = UInt8(pair, radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }

    private static func encodeHexString(_ data: Data) -> String {
        data.map { String(format: "%02X", $0) }.joined()
    }

    private enum TJToken {
        case literal(String)
        case hex(Data)
        case raw(String)

        var visibleText: String {
            switch self {
            case .literal(let encoded):
                return decodeLiteralBody(encoded)
            case .hex(let data):
                return String(data: data, encoding: .isoLatin1) ?? ""
            case .raw:
                return ""
            }
        }

        var encoded: String {
            switch self {
            case .literal(let encoded):
                return "(\(encoded))"
            case .hex(let data):
                return "<\(encodeHexString(data))>"
            case .raw(let raw):
                return raw
            }
        }
    }

    private static func rewriteTJArrayOperator(
        _ whole: String,
        oldText: String,
        newText: String,
        toUnicodeCMap: ToUnicodeCMap?
    ) throws -> (visibleText: String, replacement: String?)? {
        guard let open = whole.firstIndex(of: "["),
              let close = whole.lastIndex(of: "]"),
              open < close else {
            return nil
        }

        let body = String(whole[whole.index(after: open)..<close])
        var tokens = parseTJTokens(body)
        let visible = try tokens.map {
            try visibleText(for: $0, toUnicodeCMap: toUnicodeCMap)
        }.joined()
        let occurrences = ranges(of: oldText, in: visible)

        guard !occurrences.isEmpty else {
            return (visible, nil)
        }
        guard occurrences.count == 1, let occurrence = occurrences.first else {
            throw RewriteError.ambiguousTarget
        }

        let lowerOffset = visible.distance(from: visible.startIndex, to: occurrence.lowerBound)
        let upperOffset = visible.distance(from: visible.startIndex, to: occurrence.upperBound)

        var runningOffset = 0
        var firstAffectedIndex: Int?
        var lastAffectedIndex: Int?

        for index in tokens.indices {
            let decoded: String
            switch tokens[index] {
            case .literal, .hex:
                decoded = try visibleText(
                    for: tokens[index],
                    toUnicodeCMap: toUnicodeCMap
                )
            case .raw:
                continue
            }

            let start = runningOffset
            let end = runningOffset + decoded.count

            if max(start, lowerOffset) < min(end, upperOffset) {
                if firstAffectedIndex == nil { firstAffectedIndex = index }
                lastAffectedIndex = index
            }

            runningOffset = end
        }

        guard let firstIndex = firstAffectedIndex,
              let lastIndex = lastAffectedIndex else {
            return (visible, nil)
        }

        // Preserve all numeric TJ spacing operators. The replacement text is
        // inserted in the first affected literal; the removed portion is
        // deleted across subsequent affected literals, while suffix text is
        // retained in the last affected literal.
        runningOffset = 0
        for index in tokens.indices {
            let decoded: String
            let originalHexData: Data?

            switch tokens[index] {
            case .literal:
                decoded = try visibleText(
                    for: tokens[index],
                    toUnicodeCMap: toUnicodeCMap
                )
                originalHexData = nil
            case .hex(let data):
                decoded = try visibleText(
                    for: tokens[index],
                    toUnicodeCMap: toUnicodeCMap
                )
                originalHexData = data
            case .raw:
                continue
            }

            let tokenStart = runningOffset
            let tokenEnd = runningOffset + decoded.count
            runningOffset = tokenEnd

            guard index >= firstIndex, index <= lastIndex else { continue }

            let prefixCount = max(0, min(decoded.count, lowerOffset - tokenStart))
            let suffixStart = max(0, min(decoded.count, upperOffset - tokenStart))

            let prefixEnd = decoded.index(decoded.startIndex, offsetBy: prefixCount)
            let suffixIndex = decoded.index(decoded.startIndex, offsetBy: suffixStart)

            let prefix = index == firstIndex ? String(decoded[..<prefixEnd]) : ""
            let suffix = index == lastIndex ? String(decoded[suffixIndex...]) : ""
            let replacementChunk = index == firstIndex ? newText : ""
            let newVisible = prefix + replacementChunk + suffix

            if let originalHexData {
                let bytes: Data
                if let toUnicodeCMap,
                   toUnicodeCMap.decode(originalHexData) != nil {
                    guard let mapped = toUnicodeCMap.encode(newVisible) else {
                        throw RewriteError.unsupportedEncoding
                    }
                    bytes = mapped
                } else {
                    guard let latin = newVisible.data(using: .isoLatin1) else {
                        throw RewriteError.unsupportedEncoding
                    }
                    bytes = latin
                }
                tokens[index] = .hex(bytes)
            } else {
                tokens[index] = .literal(encodeLiteralBody(newVisible))
            }
        }

        let rebuilt = tokens.map(\.encoded).joined(separator: " ")
        return (visible, "[\(rebuilt)] TJ")
    }

    private static func visibleText(
        for token: TJToken,
        toUnicodeCMap: ToUnicodeCMap?
    ) throws -> String {
        switch token {
        case .literal(let encoded):
            return decodeLiteralBody(encoded)
        case .hex(let data):
            if let toUnicodeCMap,
               let mapped = toUnicodeCMap.decode(data) {
                return mapped
            }
            guard let latin = String(data: data, encoding: .isoLatin1) else {
                throw RewriteError.unsupportedEncoding
            }
            return latin
        case .raw:
            return ""
        }
    }

    private static func parseTJTokens(_ body: String) -> [TJToken] {
        var tokens: [TJToken] = []
        var index = body.startIndex

        while index < body.endIndex {
            if body[index].isWhitespace {
                index = body.index(after: index)
                continue
            }

            if body[index] == "(" {
                let open = index
                var cursor = body.index(after: index)
                var depth = 1
                var escaped = false

                while cursor < body.endIndex, depth > 0 {
                    let character = body[cursor]
                    if escaped {
                        escaped = false
                    } else if character == "\\" {
                        escaped = true
                    } else if character == "(" {
                        depth += 1
                    } else if character == ")" {
                        depth -= 1
                    }
                    cursor = body.index(after: cursor)
                }

                if depth == 0 {
                    let contentStart = body.index(after: open)
                    let contentEnd = body.index(before: cursor)
                    tokens.append(.literal(String(body[contentStart..<contentEnd])))
                    index = cursor
                    continue
                }
            }

            if body[index] == "<" {
                let contentStart = body.index(after: index)
                if let close = body[contentStart...].firstIndex(of: ">") {
                    let rawHex = String(body[contentStart..<close])
                        .filter { !$0.isWhitespace }
                    if let data = decodeHexString(rawHex) {
                        tokens.append(.hex(data))
                        index = body.index(after: close)
                        continue
                    }
                }
            }

            let start = index
            while index < body.endIndex,
                  !body[index].isWhitespace,
                  body[index] != "(",
                  body[index] != "<" {
                index = body.index(after: index)
            }
            tokens.append(.raw(String(body[start..<index])))
        }

        return tokens
    }

    private static func ranges(of needle: String, in haystack: String) -> [Range<String.Index>] {
        guard !needle.isEmpty else { return [] }
        var results: [Range<String.Index>] = []
        var searchStart = haystack.startIndex

        while searchStart < haystack.endIndex,
              let range = haystack.range(of: needle, range: searchStart..<haystack.endIndex) {
            results.append(range)
            searchStart = range.upperBound
        }

        return results
    }

    private static func writeIncrementalStreamRevision(
        originalData: Data,
        stream: StreamObject,
        rewrittenDecodedData: Data,
        fileURL: URL
    ) throws {
        let newEncodedData = stream.isFlateEncoded
            ? try zlibEncode(rewrittenDecodedData)
            : rewrittenDecodedData

        let previousXref = try lastStartXref(in: originalData)
        let trailer = try trailerInfo(in: originalData)
        let rewrittenDictionary = replacingLength(
            in: stream.dictionary,
            with: newEncodedData.count
        )

        let updatedData = makeIncrementalRevision(
            originalData: originalData,
            objectNumber: stream.objectNumber,
            generation: stream.generation,
            dictionary: rewrittenDictionary,
            streamData: newEncodedData,
            previousXref: previousXref,
            trailerSize: max(trailer.size, stream.objectNumber + 1),
            rootObjectNumber: trailer.rootObjectNumber,
            rootGeneration: trailer.rootGeneration
        )

        do {
            try updatedData.write(to: fileURL, options: .atomic)
        } catch {
            throw RewriteError.writeFailed
        }
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
        let fullRange = NSRange(dictionary.startIndex..<dictionary.endIndex, in: dictionary)

        let indirectPattern = #"/Length\s+\d+\s+\d+\s+R"#
        if let regex = try? NSRegularExpression(pattern: indirectPattern),
           regex.firstMatch(in: dictionary, range: fullRange) != nil {
            return regex.stringByReplacingMatches(
                in: dictionary,
                range: fullRange,
                withTemplate: "/Length \(length)"
            )
        }

        let directPattern = #"/Length\s+\d+"#
        if let regex = try? NSRegularExpression(pattern: directPattern),
           regex.firstMatch(in: dictionary, range: fullRange) != nil {
            return regex.stringByReplacingMatches(
                in: dictionary,
                range: fullRange,
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

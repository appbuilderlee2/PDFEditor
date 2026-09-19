import Foundation

/// Conservative first write-back backend for existing PDF text.
///
/// This implementation intentionally supports only a narrow, verifiable case:
/// an uncompressed literal-string `Tj` operator whose replacement keeps the
/// same encoded byte length. Keeping the byte length stable means the original
/// stream `/Length`, xref offsets, and trailer remain valid.
///
/// It performs a real content-stream byte replacement. It does not add an
/// annotation, draw an overlay, or cover the original text.
enum MinimalPDFTextRewriter {
    enum RewriteError: Error, Equatable {
        case unsupportedEncoding
        case replacementChangesEncodedLength
        case targetNotFound
        case ambiguousTarget
        case unreadableFile
        case writeFailed
    }

    static func replaceUniqueLiteralText(
        in fileURL: URL,
        oldText: String,
        newText: String
    ) throws {
        guard fileURL.isFileURL else { throw RewriteError.unreadableFile }
        guard oldText.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value <= 0x7E }),
              newText.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value <= 0x7E }) else {
            throw RewriteError.unsupportedEncoding
        }

        guard let data = try? Data(contentsOf: fileURL),
              let source = String(data: data, encoding: .isoLatin1) else {
            throw RewriteError.unreadableFile
        }

        // Match PDF literal strings immediately consumed by a Tj operator.
        // This handles escaped characters inside the literal, but deliberately
        // does not claim support for hex strings or TJ arrays yet.
        let pattern = #"\((?:\\.|[^\\)])*\)\s*Tj"#
        let regex = try NSRegularExpression(pattern: pattern)
        let fullRange = NSRange(source.startIndex..<source.endIndex, in: source)

        struct Candidate {
            let bodyRange: Range<String.Index>
            let replacementBody: String
        }

        var candidates: [Candidate] = []

        for match in regex.matches(in: source, range: fullRange) {
            guard let wholeRange = Range(match.range, in: source),
                  let open = source[wholeRange].firstIndex(of: "(") else { continue }

            let operatorSlice = source[wholeRange]
            guard let closeRelative = operatorSlice.lastIndex(of: ")") else { continue }
            let close = closeRelative

            let bodyStart = source.index(after: open)
            let bodyRange = bodyStart..<close
            let encodedBody = String(source[bodyRange])
            let decodedBody = decodeLiteralBody(encodedBody)

            guard let occurrence = decodedBody.range(of: oldText) else { continue }
            guard decodedBody[occurrence.upperBound...].range(of: oldText) == nil else {
                // Multiple occurrences in a single Tj object are ambiguous for
                // this first milestone.
                continue
            }

            var replaced = decodedBody
            replaced.replaceSubrange(occurrence, with: newText)
            let replacementBody = encodeLiteralBody(replaced)

            guard replacementBody.utf8.count == encodedBody.utf8.count else {
                throw RewriteError.replacementChangesEncodedLength
            }

            candidates.append(Candidate(bodyRange: bodyRange, replacementBody: replacementBody))
        }

        guard !candidates.isEmpty else { throw RewriteError.targetNotFound }
        guard candidates.count == 1 else { throw RewriteError.ambiguousTarget }

        let candidate = candidates[0]
        var rewritten = source
        rewritten.replaceSubrange(candidate.bodyRange, with: candidate.replacementBody)

        guard let output = rewritten.data(using: .isoLatin1) else {
            throw RewriteError.unsupportedEncoding
        }

        do {
            try output.write(to: fileURL, options: .atomic)
        } catch {
            throw RewriteError.writeFailed
        }
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
                // Preserve unknown escapes conservatively.
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

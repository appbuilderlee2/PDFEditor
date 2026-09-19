import Compression
import PDFKit
import XCTest
@testable import PDFEditorApp

@MainActor
final class PDFEditorTests: XCTestCase {
    func testDocumentStateClampsSelectionAfterPageChanges() {
        var state = DocumentState(
            pages: [
                PDFPageModel(index: 0),
                PDFPageModel(index: 1),
                PDFPageModel(index: 2)
            ],
            currentPageIndex: 2
        )

        state.replacePages(with: [PDFPageModel(index: 0)])

        XCTAssertEqual(state.currentPageIndex, 0)
        XCTAssertEqual(state.pages.count, 1)
    }

    func testRotationNormalization() {
        XCTAssertEqual(PDFUtils.normalizedRotation(450), 90)
        XCTAssertEqual(PDFUtils.normalizedRotation(-90), 270)
    }

    func testEnginePageLifecycleAndDirtyState() throws {
        let pdfDocument = PDFDocument()
        let firstPage = PDFPage()
        let secondPage = PDFPage()
        pdfDocument.insert(firstPage, at: 0)
        pdfDocument.insert(secondPage, at: 1)
        let wrapper = PDFDocumentWrapper(pdfDocument: pdfDocument)
        let engine = PDFKitEngine.shared

        XCTAssertEqual(engine.getPageCount(wrapper), 2)
        XCTAssertFalse(wrapper.isModified)

        try engine.rotatePage(wrapper, at: 0, rotation: 450)
        XCTAssertEqual(pdfDocument.page(at: 0)?.rotation, 90)
        XCTAssertTrue(wrapper.isModified)

        try engine.reorderPages(wrapper, from: 0, to: 1)
        XCTAssertTrue(pdfDocument.page(at: 1) === firstPage)

        try engine.duplicatePage(wrapper, at: 1)
        XCTAssertEqual(engine.getPageCount(wrapper), 3)
        XCTAssertFalse(pdfDocument.page(at: 2) === firstPage)

        try engine.removePage(wrapper, at: 2)
        XCTAssertEqual(engine.getPageCount(wrapper), 2)
    }

    func testPageMutationUndoRedoRoundTrip() {
        let pdfDocument = PDFDocument()
        pdfDocument.insert(PDFPage(), at: 0)
        let wrapper = PDFDocumentWrapper(pdfDocument: pdfDocument)
        let controller = DocumentController()
        controller.loadDocument(wrapper)

        controller.rotatePage(at: 0)
        XCTAssertEqual(pdfDocument.page(at: 0)?.rotation, 90)
        XCTAssertTrue(controller.history.canUndo)

        controller.history.undo()
        XCTAssertEqual(pdfDocument.page(at: 0)?.rotation, 0)
        XCTAssertTrue(controller.history.canRedo)

        controller.history.redo()
        XCTAssertEqual(pdfDocument.page(at: 0)?.rotation, 90)
    }

    func testExistingTextWritebackFailsExplicitlyWithoutMutation() {
        let pdfDocument = PDFDocument()
        pdfDocument.insert(PDFPage(), at: 0)
        let wrapper = PDFDocumentWrapper(pdfDocument: pdfDocument)

        do {
            try PDFContentEngine.shared.replaceText(
                document: wrapper,
                pageIndex: 0,
                oldText: "old",
                newText: "new"
            )
            XCTFail("Expected unsupportedContentWriteback")
        } catch let error as PDFContentError {
            guard case .textNotFound = error else {
                return XCTFail("Unexpected PDFContentError: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertFalse(wrapper.isModified)
        XCTAssertEqual(pdfDocument.pageCount, 1)
    }

    func testExistingLiteralTextWritebackChangesRealPDFBytes() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PDFEditor-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }

        try writeMinimalLiteralTextPDF(to: url, text: "Hello 100")

        guard let original = PDFDocument(url: url) else {
            return XCTFail("Fixture PDF should open in PDFKit")
        }
        XCTAssertTrue(original.page(at: 0)?.string?.contains("Hello 100") == true)

        let wrapper = PDFDocumentWrapper(url: url, pdfDocument: original)
        try PDFContentEngine.shared.replaceText(
            document: wrapper,
            pageIndex: 0,
            oldText: "100",
            newText: "120"
        )

        guard let reopened = PDFDocument(url: url) else {
            return XCTFail("Rewritten PDF should reopen in PDFKit")
        }
        let extracted = reopened.page(at: 0)?.string ?? ""
        XCTAssertTrue(extracted.contains("Hello 120"))
        XCTAssertFalse(extracted.contains("Hello 100"))

        let rawData = try Data(contentsOf: url)
        let raw = String(data: rawData, encoding: .isoLatin1) ?? ""
        // Incremental update intentionally preserves the previous PDF revision
        // while the newest xref points at the replacement stream object.
        XCTAssertTrue(raw.contains("(Hello 120) Tj"))
        XCTAssertGreaterThanOrEqual(
            raw.components(separatedBy: "startxref").count - 1,
            2
        )
    }

    func testExistingLiteralTextWritebackSupportsLengthChange() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PDFEditor-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }

        try writeMinimalLiteralTextPDF(to: url, text: "Hello 100")
        guard let pdf = PDFDocument(url: url) else {
            return XCTFail("Fixture PDF should open in PDFKit")
        }

        let wrapper = PDFDocumentWrapper(url: url, pdfDocument: pdf)
        try PDFContentEngine.shared.replaceText(
            document: wrapper,
            pageIndex: 0,
            oldText: "100",
            newText: "1200"
        )

        guard let reopened = PDFDocument(url: url) else {
            return XCTFail("Variable-length rewritten PDF should reopen")
        }
        let extracted = reopened.page(at: 0)?.string ?? ""
        XCTAssertTrue(extracted.contains("Hello 1200"))
        XCTAssertFalse(extracted.contains("Hello 100"))
    }

    func testCompressedLiteralTextWritebackSupportsLengthChange() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("compressed-literal-tj-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }

        try writeMinimalLiteralTextPDF(to: url, text: "Hello 100", compressed: true)
        guard let pdf = PDFDocument(url: url) else {
            return XCTFail("Compressed fixture PDF should open in PDFKit")
        }
        XCTAssertTrue(pdf.page(at: 0)?.string?.contains("Hello 100") == true)

        let wrapper = PDFDocumentWrapper(url: url, pdfDocument: pdf)
        try PDFContentEngine.shared.replaceText(
            document: wrapper,
            pageIndex: 0,
            oldText: "100",
            newText: "1200"
        )

        guard let reopened = PDFDocument(url: url) else {
            return XCTFail("Compressed rewritten PDF should reopen")
        }
        let extracted = reopened.page(at: 0)?.string ?? ""
        XCTAssertTrue(extracted.contains("Hello 1200"))
        XCTAssertFalse(extracted.contains("Hello 100"))
    }

    func testCompressedIncrementalWritebackCanBeAppliedTwice() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("compressed-literal-tj-twice-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }

        try writeMinimalLiteralTextPDF(to: url, text: "Hello 100", compressed: true)
        guard let original = PDFDocument(url: url) else {
            return XCTFail("Compressed fixture should open")
        }

        let wrapper = PDFDocumentWrapper(url: url, pdfDocument: original)
        try PDFContentEngine.shared.replaceText(
            document: wrapper,
            pageIndex: 0,
            oldText: "100",
            newText: "1200"
        )
        try PDFContentEngine.shared.replaceText(
            document: wrapper,
            pageIndex: 0,
            oldText: "1200",
            newText: "13000"
        )

        guard let reopened = PDFDocument(url: url) else {
            return XCTFail("Twice-updated PDF should reopen")
        }
        let extracted = reopened.page(at: 0)?.string ?? ""
        XCTAssertTrue(extracted.contains("Hello 13000"))
        XCTAssertFalse(extracted.contains("Hello 1200"))
        XCTAssertFalse(extracted.contains("Hello 100"))
    }

    func testTJArrayWritebackAcrossLiteralSegments() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tj-array-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }

        try writeTJArrayPDF(to: url, compressed: false)
        guard let pdf = PDFDocument(url: url) else {
            return XCTFail("TJ fixture should open")
        }

        XCTAssertTrue(pdf.page(at: 0)?.string?.contains("Hello 100") == true)

        let wrapper = PDFDocumentWrapper(url: url, pdfDocument: pdf)
        try PDFContentEngine.shared.replaceText(
            document: wrapper,
            pageIndex: 0,
            oldText: "100",
            newText: "1200"
        )

        guard let reopened = PDFDocument(url: url) else {
            return XCTFail("Rewritten TJ PDF should reopen")
        }
        let extracted = reopened.page(at: 0)?.string ?? ""
        XCTAssertTrue(extracted.contains("Hello 1200"))
        XCTAssertFalse(extracted.contains("Hello 100"))
    }

    func testCompressedTJArrayWritebackAcrossLiteralSegments() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tj-array-compressed-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }

        try writeTJArrayPDF(to: url, compressed: true)
        guard let pdf = PDFDocument(url: url) else {
            return XCTFail("Compressed TJ fixture should open")
        }

        XCTAssertTrue(pdf.page(at: 0)?.string?.contains("Hello 100") == true)

        let wrapper = PDFDocumentWrapper(url: url, pdfDocument: pdf)
        try PDFContentEngine.shared.replaceText(
            document: wrapper,
            pageIndex: 0,
            oldText: "Hello 100",
            newText: "Hi 1200"
        )

        guard let reopened = PDFDocument(url: url) else {
            return XCTFail("Compressed rewritten TJ PDF should reopen")
        }
        let extracted = reopened.page(at: 0)?.string ?? ""
        XCTAssertTrue(extracted.contains("Hi 1200"))
        XCTAssertFalse(extracted.contains("Hello 100"))
    }

    func testHexTjWritebackSupportsLengthChange() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hex-tj-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }

        try writeHexTjPDF(to: url, compressed: false)
        guard let pdf = PDFDocument(url: url) else {
            return XCTFail("Hex Tj fixture should open")
        }
        XCTAssertTrue(pdf.page(at: 0)?.string?.contains("Hello 100") == true)

        let wrapper = PDFDocumentWrapper(url: url, pdfDocument: pdf)
        try PDFContentEngine.shared.replaceText(
            document: wrapper,
            pageIndex: 0,
            oldText: "100",
            newText: "1200"
        )

        guard let reopened = PDFDocument(url: url) else {
            return XCTFail("Rewritten hex Tj PDF should reopen")
        }
        let extracted = reopened.page(at: 0)?.string ?? ""
        XCTAssertTrue(extracted.contains("Hello 1200"))
        XCTAssertFalse(extracted.contains("Hello 100"))
    }

    func testCompressedHexTjWritebackSupportsLengthChange() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hex-tj-compressed-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }

        try writeHexTjPDF(to: url, compressed: true)
        guard let pdf = PDFDocument(url: url) else {
            return XCTFail("Compressed hex Tj fixture should open")
        }
        XCTAssertTrue(pdf.page(at: 0)?.string?.contains("Hello 100") == true)

        let wrapper = PDFDocumentWrapper(url: url, pdfDocument: pdf)
        try PDFContentEngine.shared.replaceText(
            document: wrapper,
            pageIndex: 0,
            oldText: "Hello 100",
            newText: "Hi 1200"
        )

        guard let reopened = PDFDocument(url: url) else {
            return XCTFail("Compressed rewritten hex Tj PDF should reopen")
        }
        let extracted = reopened.page(at: 0)?.string ?? ""
        XCTAssertTrue(extracted.contains("Hi 1200"))
        XCTAssertFalse(extracted.contains("Hello 100"))
    }

    func testMixedLiteralAndHexTJArrayWriteback() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tj-mixed-hex-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }

        try writeMixedHexTJArrayPDF(to: url, compressed: false)
        guard let pdf = PDFDocument(url: url) else {
            return XCTFail("Mixed TJ fixture should open")
        }
        XCTAssertTrue(pdf.page(at: 0)?.string?.contains("Hello 100") == true)

        let wrapper = PDFDocumentWrapper(url: url, pdfDocument: pdf)
        try PDFContentEngine.shared.replaceText(
            document: wrapper,
            pageIndex: 0,
            oldText: "Hello 100",
            newText: "Hi 1200"
        )

        guard let reopened = PDFDocument(url: url) else {
            return XCTFail("Mixed TJ rewritten PDF should reopen")
        }
        let extracted = reopened.page(at: 0)?.string ?? ""
        XCTAssertTrue(extracted.contains("Hi 1200"))
        XCTAssertFalse(extracted.contains("Hello 100"))
    }

    func testCompressedMixedLiteralAndHexTJArrayWriteback() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tj-mixed-hex-compressed-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }

        try writeMixedHexTJArrayPDF(to: url, compressed: true)
        guard let pdf = PDFDocument(url: url) else {
            return XCTFail("Compressed mixed TJ fixture should open")
        }
        XCTAssertTrue(pdf.page(at: 0)?.string?.contains("Hello 100") == true)

        let wrapper = PDFDocumentWrapper(url: url, pdfDocument: pdf)
        try PDFContentEngine.shared.replaceText(
            document: wrapper,
            pageIndex: 0,
            oldText: "100",
            newText: "1200"
        )

        guard let reopened = PDFDocument(url: url) else {
            return XCTFail("Compressed mixed TJ rewritten PDF should reopen")
        }
        let extracted = reopened.page(at: 0)?.string ?? ""
        XCTAssertTrue(extracted.contains("Hello 1200"))
        XCTAssertFalse(extracted.contains("Hello 100"))
    }

    func testType0IdentityHToUnicodeCIDWriteback() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("type0-tounicode-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }

        try writeType0ToUnicodePDF(to: url, compressed: true)

        guard let pdf = PDFDocument(url: url) else {
            return XCTFail("Type0 ToUnicode fixture should open")
        }
        let originalText = pdf.page(at: 0)?.string ?? ""
        XCTAssertTrue(originalText.contains("你好100"))

        let wrapper = PDFDocumentWrapper(url: url, pdfDocument: pdf)
        try PDFContentEngine.shared.replaceText(
            document: wrapper,
            pageIndex: 0,
            oldText: "你好100",
            newText: "您好1200"
        )

        guard let reopened = PDFDocument(url: url) else {
            return XCTFail("Rewritten Type0 PDF should reopen")
        }
        let extracted = reopened.page(at: 0)?.string ?? ""
        XCTAssertTrue(extracted.contains("您好1200"))
        XCTAssertFalse(extracted.contains("你好100"))
    }

    func testType0IdentityHToUnicodeCIDTJArrayWriteback() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("type0-tounicode-tj-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }

        try writeType0ToUnicodePDF(
            to: url,
            compressed: true,
            useTJArray: true
        )

        guard let pdf = PDFDocument(url: url) else {
            return XCTFail("Type0 TJ fixture should open")
        }
        XCTAssertTrue(pdf.page(at: 0)?.string?.contains("你好100") == true)

        let wrapper = PDFDocumentWrapper(url: url, pdfDocument: pdf)
        try PDFContentEngine.shared.replaceText(
            document: wrapper,
            pageIndex: 0,
            oldText: "你好100",
            newText: "您好1200"
        )

        guard let reopened = PDFDocument(url: url) else {
            return XCTFail("Rewritten Type0 TJ PDF should reopen")
        }
        let extracted = reopened.page(at: 0)?.string ?? ""
        XCTAssertTrue(extracted.contains("您好1200"))
        XCTAssertFalse(extracted.contains("你好100"))
    }

    func testIndirectLengthCompressedWriteback() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("indirect-length-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }

        let streamText = "BT\n/F1 12 Tf\n72 720 Td\n(Hello 100) Tj\nET\n"
        try writeCustomContentPDF(
            to: url,
            streamText: streamText,
            compressed: true,
            indirectLength: true
        )

        guard let pdf = PDFDocument(url: url) else {
            return XCTFail("Indirect-Length fixture should open")
        }
        XCTAssertTrue(pdf.page(at: 0)?.string?.contains("Hello 100") == true)

        let wrapper = PDFDocumentWrapper(url: url, pdfDocument: pdf)
        try PDFContentEngine.shared.replaceText(
            document: wrapper,
            pageIndex: 0,
            oldText: "100",
            newText: "1200"
        )

        guard let reopened = PDFDocument(url: url) else {
            return XCTFail("Rewritten indirect-Length PDF should reopen")
        }
        let extracted = reopened.page(at: 0)?.string ?? ""
        XCTAssertTrue(extracted.contains("Hello 1200"))
        XCTAssertFalse(extracted.contains("Hello 100"))
    }

    func testAmbiguousWritebackFailsWithoutCorruptingPDF() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PDFEditor-ambiguous-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }

        try writeMinimalLiteralTextPDF(to: url, text: "100 and 100")
        let before = try Data(contentsOf: url)
        guard let pdf = PDFDocument(url: url) else {
            return XCTFail("Fixture PDF should open")
        }

        let wrapper = PDFDocumentWrapper(url: url, pdfDocument: pdf)
        XCTAssertThrowsError(
            try PDFContentEngine.shared.replaceText(
                document: wrapper,
                pageIndex: 0,
                oldText: "100",
                newText: "1200"
            )
        )

        let after = try Data(contentsOf: url)
        XCTAssertEqual(before, after)
        guard let reopened = PDFDocument(url: url) else {
            return XCTFail("Failed writeback must leave a valid PDF")
        }
        XCTAssertTrue(reopened.page(at: 0)?.string?.contains("100 and 100") == true)
    }

    private func writeType0ToUnicodePDF(
        to url: URL,
        compressed: Bool,
        useTJArray: Bool = false
    ) throws {
        let textOperator = useTJArray
            ? "[<0001> -25 <0002> 10 <001100100010>] TJ"
            : "<00010002001100100010> Tj"
        let content = "BT\n/F1 16 Tf\n72 720 Td\n\(textOperator)\nET\n"
        guard let contentPlain = content.data(using: .ascii) else {
            throw NSError(domain: "PDFEditorTests", code: 10)
        }
        let contentData = compressed ? try zlibEncodeForFixture(contentPlain) : contentPlain

        let cmap = """
        /CIDInit /ProcSet findresource begin
        12 dict begin
        begincmap
        /CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def
        /CMapName /Adobe-Identity-UCS def
        /CMapType 2 def
        1 begincodespacerange
        <0000> <FFFF>
        endcodespacerange
        3 beginbfchar
        <0001> <4F60>
        <0002> <597D>
        <0003> <60A8>
        endbfchar
        1 beginbfrange
        <0010> <0012> <0030>
        endbfrange
        endcmap
        CMapName currentdict /CMap defineresource pop
        end
        end
        """
        guard let cmapPlain = cmap.data(using: .ascii) else {
            throw NSError(domain: "PDFEditorTests", code: 11)
        }
        let cmapData = compressed ? try zlibEncodeForFixture(cmapPlain) : cmapPlain
        let filter = compressed ? " /Filter /FlateDecode" : ""

        var pdf = Data("%PDF-1.4\n".utf8)
        var offsets: [Int] = [0]

        func appendObject(_ number: Int, header: String, stream: Data? = nil) {
            while offsets.count <= number { offsets.append(-1) }
            offsets[number] = pdf.count
            pdf.append(contentsOf: "\(number) 0 obj\n".utf8)
            pdf.append(contentsOf: header.utf8)
            if let stream {
                pdf.append(contentsOf: "\nstream\n".utf8)
                pdf.append(stream)
                pdf.append(contentsOf: "\nendstream".utf8)
            }
            pdf.append(contentsOf: "\nendobj\n".utf8)
        }

        appendObject(1, header: "<< /Type /Catalog /Pages 2 0 R >>")
        appendObject(2, header: "<< /Type /Pages /Kids [3 0 R] /Count 1 >>")
        appendObject(
            3,
            header: "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 4 0 R >> >> /Contents 8 0 R >>"
        )
        appendObject(
            4,
            header: "<< /Type /Font /Subtype /Type0 /BaseFont /TestCID /Encoding /Identity-H /DescendantFonts [5 0 R] /ToUnicode 7 0 R >>"
        )
        appendObject(
            5,
            header: "<< /Type /Font /Subtype /CIDFontType2 /BaseFont /Helvetica /CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >> /FontDescriptor 6 0 R /DW 1000 /CIDToGIDMap /Identity >>"
        )
        appendObject(
            6,
            header: "<< /Type /FontDescriptor /FontName /Helvetica /Flags 32 /FontBBox [0 -200 1000 900] /ItalicAngle 0 /Ascent 800 /Descent -200 /CapHeight 700 /StemV 80 >>"
        )
        appendObject(
            7,
            header: "<< /Length \(cmapData.count)\(filter) >>",
            stream: cmapData
        )
        appendObject(
            8,
            header: "<< /Length \(contentData.count)\(filter) >>",
            stream: contentData
        )

        let objectCount = 8
        let xrefOffset = pdf.count
        pdf.append(contentsOf: "xref\n0 \(objectCount + 1)\n".utf8)
        pdf.append(contentsOf: "0000000000 65535 f \n".utf8)
        for number in 1...objectCount {
            pdf.append(contentsOf: String(format: "%010d 00000 n \n", offsets[number]).utf8)
        }
        pdf.append(contentsOf: "trailer\n<< /Size \(objectCount + 1) /Root 1 0 R >>\n".utf8)
        pdf.append(contentsOf: "startxref\n\(xrefOffset)\n%%EOF\n".utf8)

        try pdf.write(to: url, options: .atomic)
    }

    private func writeMixedHexTJArrayPDF(
        to url: URL,
        compressed: Bool
    ) throws {
        let hex = Data("100".utf8)
            .map { String(format: "%02X", $0) }
            .joined()
        let streamText = "BT\n/F1 12 Tf\n72 720 Td\n[(Hello ) -20 <\(hex)>] TJ\nET\n"
        try writeCustomContentPDF(to: url, streamText: streamText, compressed: compressed)
    }

    private func writeHexTjPDF(
        to url: URL,
        compressed: Bool
    ) throws {
        let hex = Data("Hello 100".utf8)
            .map { String(format: "%02X", $0) }
            .joined()
        let streamText = "BT\n/F1 12 Tf\n72 720 Td\n<\(hex)> Tj\nET\n"
        try writeCustomContentPDF(to: url, streamText: streamText, compressed: compressed)
    }

    private func writeTJArrayPDF(
        to url: URL,
        compressed: Bool
    ) throws {
        let streamText = "BT\n/F1 12 Tf\n72 720 Td\n[(Hello ) -20 (100)] TJ\nET\n"
        try writeCustomContentPDF(to: url, streamText: streamText, compressed: compressed)
    }

    private func writeCustomContentPDF(
        to url: URL,
        streamText: String,
        compressed: Bool,
        indirectLength: Bool = false
    ) throws {
        guard let plainStream = streamText.data(using: .ascii) else {
            throw NSError(domain: "PDFEditorTests", code: 3)
        }
        let streamData = compressed ? try zlibEncodeForFixture(plainStream) : plainStream

        var pdf = Data("%PDF-1.4\n".utf8)
        var offsets: [Int] = [0]

        func appendObject(_ number: Int, header: String, stream: Data? = nil) {
            offsets.append(pdf.count)
            pdf.append(contentsOf: "\(number) 0 obj\n".utf8)
            pdf.append(contentsOf: header.utf8)
            if let stream {
                pdf.append(contentsOf: "\nstream\n".utf8)
                pdf.append(stream)
                pdf.append(contentsOf: "\nendstream".utf8)
            }
            pdf.append(contentsOf: "\nendobj\n".utf8)
        }

        appendObject(1, header: "<< /Type /Catalog /Pages 2 0 R >>")
        appendObject(2, header: "<< /Type /Pages /Kids [3 0 R] /Count 1 >>")
        appendObject(
            3,
            header: "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>"
        )
        appendObject(4, header: "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")

        let filter = compressed ? " /Filter /FlateDecode" : ""
        if indirectLength {
            appendObject(
                5,
                header: "<< /Length 6 0 R\(filter) >>",
                stream: streamData
            )
            appendObject(6, header: "\(streamData.count)")
        } else {
            appendObject(
                5,
                header: "<< /Length \(streamData.count)\(filter) >>",
                stream: streamData
            )
        }

        let objectCount = offsets.count - 1
        let xrefOffset = pdf.count
        pdf.append(contentsOf: "xref\n0 \(objectCount + 1)\n".utf8)
        pdf.append(contentsOf: "0000000000 65535 f \n".utf8)
        for offset in offsets.dropFirst() {
            pdf.append(contentsOf: String(format: "%010d 00000 n \n", offset).utf8)
        }
        pdf.append(contentsOf: "trailer\n<< /Size \(objectCount + 1) /Root 1 0 R >>\n".utf8)
        pdf.append(contentsOf: "startxref\n\(xrefOffset)\n%%EOF\n".utf8)

        try pdf.write(to: url, options: .atomic)
    }

    private func writeMinimalLiteralTextPDF(
        to url: URL,
        text: String,
        compressed: Bool = false
    ) throws {
        let streamText = "BT\n/F1 12 Tf\n72 720 Td\n(\(text)) Tj\nET\n"
        try writeCustomContentPDF(to: url, streamText: streamText, compressed: compressed)
    }

    private func zlibEncodeForFixture(_ input: Data) throws -> Data {
        var capacity = max(input.count * 2, input.count + 1024)
        while capacity <= 4 * 1024 * 1024 {
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
                var wrapped = Data([0x78, 0x9C])
                wrapped.append(raw)

                let checksum = adler32ForFixture(input)
                wrapped.append(UInt8((checksum >> 24) & 0xFF))
                wrapped.append(UInt8((checksum >> 16) & 0xFF))
                wrapped.append(UInt8((checksum >> 8) & 0xFF))
                wrapped.append(UInt8(checksum & 0xFF))
                return wrapped
            }
            capacity *= 2
        }
        throw NSError(domain: "PDFEditorTests", code: 2)
    }

    private func adler32ForFixture(_ data: Data) -> UInt32 {
        let modulus: UInt32 = 65_521
        var a: UInt32 = 1
        var b: UInt32 = 0
        for byte in data {
            a = (a + UInt32(byte)) % modulus
            b = (b + a) % modulus
        }
        return (b << 16) | a
    }

}

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
            guard case .unsupportedContentWriteback = error else {
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
        XCTAssertTrue(raw.contains("(Hello 120) Tj"))
        XCTAssertFalse(raw.contains("(Hello 100) Tj"))
    }

    func testExistingLiteralTextWritebackRejectsLengthChange() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PDFEditor-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }

        try writeMinimalLiteralTextPDF(to: url, text: "Hello 100")
        guard let pdf = PDFDocument(url: url) else {
            return XCTFail("Fixture PDF should open in PDFKit")
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

        let rawData = try Data(contentsOf: url)
        let raw = String(data: rawData, encoding: .isoLatin1) ?? ""
        XCTAssertTrue(raw.contains("(Hello 100) Tj"))
        XCTAssertFalse(raw.contains("(Hello 1200) Tj"))
    }

    private func writeMinimalLiteralTextPDF(to url: URL, text: String) throws {
        let stream = "BT\n/F1 12 Tf\n72 720 Td\n(\(text)) Tj\nET\n"
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
            "<< /Length \(stream.utf8.count) >>\nstream\n\(stream)endstream"
        ]

        var pdf = "%PDF-1.4\n"
        var offsets: [Int] = [0]

        for (index, object) in objects.enumerated() {
            offsets.append(pdf.utf8.count)
            pdf += "\(index + 1) 0 obj\n\(object)\nendobj\n"
        }

        let xrefOffset = pdf.utf8.count
        pdf += "xref\n0 \(objects.count + 1)\n"
        pdf += "0000000000 65535 f \n"
        for offset in offsets.dropFirst() {
            pdf += String(format: "%010d 00000 n \n", offset)
        }
        pdf += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\n"
        pdf += "startxref\n\(xrefOffset)\n%%EOF\n"

        guard let data = pdf.data(using: .ascii) else {
            throw NSError(domain: "PDFEditorTests", code: 1)
        }
        try data.write(to: url, options: .atomic)
    }

}

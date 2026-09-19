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
}

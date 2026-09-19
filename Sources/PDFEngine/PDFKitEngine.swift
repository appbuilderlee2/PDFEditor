// Apple PDFKit implementation. All access is main-actor isolated because
// PDFDocument and PDFPage are mutable, non-Sendable reference types.
import CoreGraphics
import Foundation
import PDFKit

@MainActor
public final class PDFKitEngine: PDFEngine {
    public static let shared = PDFKitEngine()

    private init() {}

    public func openDocument(at url: URL) throws -> PDFDocumentWrapper {
        guard url.isFileURL, let pdfDocument = PDFDocument(url: url) else {
            throw PDFEngineError.invalidPDF
        }
        return PDFDocumentWrapper(url: url, pdfDocument: pdfDocument)
    }

    public func saveDocument(_ document: PDFDocumentWrapper, to url: URL) throws {
        let pdfDocument = try requireDocument(document)
        guard url.isFileURL, pdfDocument.write(to: url) else {
            throw PDFEngineError.writeFailed
        }
        document.markSaved(to: url)
    }

    public func saveAs(_ document: PDFDocumentWrapper, to url: URL) throws {
        try saveDocument(document, to: url)
    }

    public func getPageCount(_ document: PDFDocumentWrapper) -> Int {
        document.pdfDocument?.pageCount ?? 0
    }

    public func getPage(_ document: PDFDocumentWrapper, at index: Int) throws -> PDFPageWrapper {
        let pdfDocument = try requireDocument(document)
        try validate(index: index, in: pdfDocument)
        guard let page = pdfDocument.page(at: index) else {
            throw PDFEngineError.pageNotFound(index)
        }
        return PDFPageWrapper(page: page, pageIndex: index)
    }

    /// Moves a page so that it occupies `destinationIndex` in the final order.
    public func reorderPages(
        _ document: PDFDocumentWrapper,
        from sourceIndex: Int,
        to destinationIndex: Int
    ) throws {
        let pdfDocument = try requireDocument(document)
        try validate(index: sourceIndex, in: pdfDocument)
        try validate(index: destinationIndex, in: pdfDocument)

        guard sourceIndex != destinationIndex else { return }
        guard let page = pdfDocument.page(at: sourceIndex) else {
            throw PDFEngineError.pageNotFound(sourceIndex)
        }

        // Remove first so the insertion index always describes the final order.
        pdfDocument.removePage(at: sourceIndex)
        pdfDocument.insert(page, at: destinationIndex)
        document.markModified()
    }

    public func removePage(_ document: PDFDocumentWrapper, at index: Int) throws {
        let pdfDocument = try requireDocument(document)
        try validate(index: index, in: pdfDocument)
        pdfDocument.removePage(at: index)
        document.markModified()
    }

    /// Sets the page rotation. PDFKit rotations are normalized to the range
    /// 0, 90, 180, or 270 degrees.
    public func rotatePage(
        _ document: PDFDocumentWrapper,
        at index: Int,
        rotation: Int
    ) throws {
        guard rotation.isMultiple(of: 90) else {
            throw PDFEngineError.invalidRotation
        }

        let pdfDocument = try requireDocument(document)
        try validate(index: index, in: pdfDocument)
        guard let page = pdfDocument.page(at: index) else {
            throw PDFEngineError.pageNotFound(index)
        }

        page.rotation = normalizedRotation(rotation)
        document.markModified()
    }

    public func duplicatePage(_ document: PDFDocumentWrapper, at index: Int) throws {
        let pdfDocument = try requireDocument(document)
        try validate(index: index, in: pdfDocument)
        guard let sourcePage = pdfDocument.page(at: index) else {
            throw PDFEngineError.pageNotFound(index)
        }
        guard let copiedPage = sourcePage.copy() as? PDFPage else {
            throw PDFEngineError.pageCopyFailed
        }

        pdfDocument.insert(copiedPage, at: index + 1)
        document.markModified()
    }

    public func getThumbnail(for page: PDFPageWrapper, size: CGSize) -> Any {
        page.page.thumbnail(of: size, for: .mediaBox)
    }

    private func requireDocument(_ wrapper: PDFDocumentWrapper) throws -> PDFDocument {
        guard let document = wrapper.pdfDocument else {
            throw PDFEngineError.noDocument
        }
        return document
    }

    private func validate(index: Int, in document: PDFDocument) throws {
        guard index >= 0, index < document.pageCount else {
            throw PDFEngineError.invalidPageIndex
        }
    }

    private func normalizedRotation(_ rotation: Int) -> Int {
        let remainder = rotation % 360
        return remainder >= 0 ? remainder : remainder + 360
    }
}

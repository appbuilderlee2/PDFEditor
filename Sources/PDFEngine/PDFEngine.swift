import CoreGraphics
import Foundation
import PDFKit

/// Main-thread interface for PDFKit-backed document operations.
///
/// PDFKit document and page objects are mutable reference types and are not
/// `Sendable`, so the complete engine boundary is isolated to the main actor.
@MainActor
public protocol PDFEngine: AnyObject {
    func openDocument(at url: URL) throws -> PDFDocumentWrapper
    func saveDocument(_ document: PDFDocumentWrapper, to url: URL) throws
    func saveAs(_ document: PDFDocumentWrapper, to url: URL) throws

    func getPageCount(_ document: PDFDocumentWrapper) -> Int
    func getPage(_ document: PDFDocumentWrapper, at index: Int) throws -> PDFPageWrapper

    func reorderPages(_ document: PDFDocumentWrapper, from sourceIndex: Int, to destinationIndex: Int) throws
    func removePage(_ document: PDFDocumentWrapper, at index: Int) throws
    func rotatePage(_ document: PDFDocumentWrapper, at index: Int, rotation: Int) throws
    func duplicatePage(_ document: PDFDocumentWrapper, at index: Int) throws

    func getThumbnail(for page: PDFPageWrapper, size: CGSize) -> Any
}

/// Reference model that owns the live PDFKit document used by the editor.
@MainActor
public final class PDFDocumentWrapper: Identifiable {
    public nonisolated let id: UUID
    public var url: URL?
    public var isModified: Bool

    // Optional for source compatibility with existing callers. Engine-created
    // wrappers always contain a document; no lazy reload or associated storage
    // is used.
    public var pdfDocument: PDFDocument?

    public init(
        id: UUID = UUID(),
        url: URL? = nil,
        pdfDocument: PDFDocument? = nil,
        isModified: Bool = false
    ) {
        self.id = id
        self.url = url
        self.pdfDocument = pdfDocument
        self.isModified = isModified
    }

    func markModified() {
        isModified = true
    }

    func markSaved(to url: URL) {
        self.url = url
        isModified = false
    }
}

/// Reference model that directly owns a PDFKit page.
@MainActor
public final class PDFPageWrapper {
    public let page: PDFPage
    public let pageIndex: Int

    public var rotation: Int {
        page.rotation
    }

    public init(page: PDFPage, pageIndex: Int) {
        self.page = page
        self.pageIndex = pageIndex
    }
}

public enum PDFEngineError: Error, LocalizedError {
    case invalidPDF
    case noDocument
    case writeFailed
    case pageNotFound(Int)
    case invalidPageIndex
    case invalidRotation
    case pageCopyFailed

    public var errorDescription: String? {
        switch self {
        case .invalidPDF:
            return "無效的 PDF 檔案"
        case .noDocument:
            return "未載入 PDF 文檔"
        case .writeFailed:
            return "寫入 PDF 失敗"
        case .pageNotFound(let index):
            return "頁面 \(index) 不存在"
        case .invalidPageIndex:
            return "頁面索引超出範圍"
        case .invalidRotation:
            return "頁面旋轉角度必須是 90 度的倍數"
        case .pageCopyFailed:
            return "無法複製頁面"
        }
    }
}

// PDFKitEngine — Apple PDFKit 具體實作
// 授權：僅使用 Apple PDFKit（系統框架），無額外授權問題。
// 備註：PDFKit 提供 high-level PDF 操作，Phase 1 足以支撐。
import PDFKit
import Foundation

final class PDFKitEngine: PDFEngine {
    static let shared = PDFKitEngine()
    private init() {}

    // MARK: - 檔案操作

    func openDocument(at url: URL) throws -> PDFDocumentWrapper {
        guard let pdfDoc = PDFDocument(url: url) else {
            throw PDFEngineError.invalidPDF
        }
        return PDFDocumentWrapper(id: UUID(), url: url, pdfDocument: pdfDoc)
    }

    func saveDocument(_ document: PDFDocumentWrapper, to url: URL) throws {
        guard let pdfDoc = document.pdfDocument else {
            throw PDFEngineError.noDocument
        }
        guard pdfDoc.write(to: url) else {
            throw PDFEngineError.writeFailed
        }
    }

    func saveAs(_ document: PDFDocumentWrapper, to url: URL) throws {
        try saveDocument(document, to: url)
    }

    // MARK: - 頁面查詢

    func getPageCount(_ document: PDFDocumentWrapper) -> Int {
        document.pdfDocument?.pageCount ?? 0
    }

    func getPage(_ document: PDFDocumentWrapper, at index: Int) throws -> PDFPageWrapper {
        guard let pdfDoc = document.pdfDocument else {
            throw PDFEngineError.noDocument
        }
        guard let page = pdfDoc.page(at: index) else {
            throw PDFEngineError.pageNotFound(index: index)
        }
        return PDFPageWrapper(page: page, pageIndex: index)
    }

    // MARK: - 頁面操作

    func reorderPages(_ document: PDFDocumentWrapper, from: Int, to: Int) throws {
        guard let pdfDoc = document.pdfDocument else {
            throw PDFEngineError.noDocument
        }
        guard from >= 0, from < pdfDoc.pageCount, to >= 0, to < pdfDoc.pageCount else {
            throw PDFEngineError.invalidPageIndex
        }
        if let page = pdfDoc.page(at: from) {
            pdfDoc.insert(page, at: to)
            if from < to {
                pdfDoc.removePage(at: from + 1)
            } else {
                pdfDoc.removePage(at: from)
            }
        }
    }

    func removePage(_ document: PDFDocumentWrapper, at index: Int) throws {
        guard let pdfDoc = document.pdfDocument else {
            throw PDFEngineError.noDocument
        }
        guard index >= 0, index < pdfDoc.pageCount else {
            throw PDFEngineError.invalidPageIndex
        }
        pdfDoc.removePage(at: index)
    }

    func rotatePage(_ document: PDFDocumentWrapper, at index: Int, rotation: Int) throws {
        guard let pdfDoc = document.pdfDocument else {
            throw PDFEngineError.noDocument
        }
        guard index >= 0, index < pdfDoc.pageCount else {
            throw PDFEngineError.invalidPageIndex
        }
        guard let page = pdfDoc.page(at: index) else {
            throw PDFEngineError.pageNotFound(index)
        }
        page.rotation = PDFPage.Rotation(rawValue: rotation) ?? .rotate0
    }

    // MARK: - 縮圖

    func getThumbnail(for page: PDFPageWrapper, size: CGSize) -> Any {
        return page.page.thumbnail(of: size, for: .mediaBox)
    }
}

// MARK: - 錯誤類型

enum PDFEngineError: Error, LocalizedError {
    case invalidPDF
    case noDocument
    case writeFailed
    case pageNotFound(Int)
    case invalidPageIndex

    var errorDescription: String? {
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
        }
    }
}

// MARK: - PDFDocumentWrapper 擴展（內部使用）

extension PDFDocumentWrapper {
    var pdfDocument: PDFDocument? {
        get {
            if let doc = _pdfDocument {
                return doc
            }
            if let url = url {
                return PDFDocument(url: url)
            }
            return nil
        }
        set {
            _pdfDocument = newValue
            if newValue == nil {
                url = nil
            }
        }
    }
    private var _pdfDocument: PDFDocument? {
        get { objc_getAssociatedObject(self, &_pdfDocumentKey) as? PDFDocument }
        set { objc_setAssociatedObject(self, &_pdfDocumentKey, newValue, .OBJC_ASSOCIATION_RETAIN) }
    }
    private static var _pdfDocumentKey = "pdfDocumentKey"
}

// MARK: - PDFPageWrapper 擴展

extension PDFPageWrapper {
    var page: PDFPage {
        _page
    }
    private var _page: PDFPage {
        get { objc_getAssociatedObject(self, &_pageKey) as? PDFPage ?? PDFPage() }
        set { objc_setAssociatedObject(self, &_pageKey, newValue, .OBJC_ASSOCIATION_RETAIN) }
    }
    private static var _pageKey = "pageKey"
}

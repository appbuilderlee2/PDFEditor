// PDFKitEngine — 具體實作，使用 Apple PDFKit
// 授權：僅使用 Apple PDFKit（系統框架），無額外授權問題。
import PDFKit

final class PDFKitEngine {
    static let shared = PDFKitEngine()
    private init() {}
    
    func openDocument(at url: URL) throws -> PDFDocumentWrapper {
        let pdfDoc = PDFDocument(url: url)
        guard let document = pdfDoc else {
            throw PDFEngineError.invalidPDF
        }
        return PDFDocumentWrapper(id: UUID(), url: url)
    }
    
    func saveDocument(_ document: PDFDocumentWrapper, to url: URL) throws {
        // 注意：這裡我們僅保存文檔，但實際上 PDFDocument 需要被修改後才能保存。
        // 為了簡化，我們假設文檔已在內存中被修改（這需要在 UI 層處理）。
        // 實際上，我們需要保存修改過的 PDFDocument 對象。
        // 這裡我們只做一個佔位符，實際應用中應該傳入修改過的 PDFDocument。
        throw PDFEngineError.notImplemented
    }
    
    func saveAs(_ document: PDFDocumentWrapper, to url: URL) throws {
        throw PDFEngineError.notImplemented
    }
    
    func getPageCount(_ document: PDFDocumentWrapper) -> Int {
        // 我們需要從某處獲取實際的 PDFDocument 對象。
        // 這裡我們返回 0 作為佔位符。
        return 0
    }
    
    func getPage(_ document: PDFDocumentWrapper, at index: Int) throws -> PDFPageWrapper {
        throw PDFEngineError.notImplemented
    }
    
    func reorderPages(_ document: PDFDocumentWrapper, from: Int, to: Int) throws {
        throw PDFEngineError.notImplemented
    }
    
    func removePage(_ document: PDFDocumentWrapper, at index: Int) throws {
        throw PDFEngineError.notImplemented
    }
    
    func rotatePage(_ document: PDFDocumentWrapper, at index: Int, rotation: Int) throws {
        throw PDFEngineError.notImplemented
    }
    
    func getThumbnail(for page: PDFPageWrapper, size: CGSize) -> Any {
        // 返回佔位符
        return NSImage()
    }
}

enum PDFEngineError: Error {
    case invalidPDF
    case notImplemented
}

// MARK: - Extensions to conform to PDFEngine

extension PDFKitEngine: PDFEngine {
    // 這些方法已在上面實作，僅作為擴展以符合協議
}
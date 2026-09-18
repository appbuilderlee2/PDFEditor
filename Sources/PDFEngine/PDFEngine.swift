/// PDFEngine — 抽象協議，包裝 PDFKit 以支援未來替換（PDFium, MuPDF 等）
/// 授權：此模組僅使用 Apple PDFKit（系統授權），不包含任何 AGPL 組件。
public protocol PDFEngine {
    func openDocument(at url: URL) throws -> PDFDocumentWrapper
    func saveDocument(_ document: PDFDocumentWrapper, to url: URL) throws
    func saveAs(_ document: PDFDocumentWrapper, to url: URL) throws
    func getPageCount(_ document: PDFDocumentWrapper) -> Int
    func getPage(_ document: PDFDocumentWrapper, at index: Int) throws -> PDFPageWrapper
    func reorderPages(_ document: PDFDocumentWrapper, from: Int, to: Int) throws
    func removePage(_ document: PDFDocumentWrapper, at index: Int) throws
    func rotatePage(_ document: PDFDocumentWrapper, at index: Int, rotation: Int) throws
    func getThumbnail(for page: PDFPageWrapper, size: CGSize) -> Any
}

public struct PDFDocumentWrapper {
    public let id: UUID
    public var url: URL?
    init(id: UUID = UUID(), url: URL? = nil) {
        self.id = id
        self.url = url
    }
}

public struct PDFPageWrapper {
    public let pageIndex: Int
    public var rotation: Int // 只支援 0/90/180/270（PDFKit 限制）
}

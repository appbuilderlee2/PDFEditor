public struct PDFDocumentWrapper {
    public let id: UUID
    public var url: URL?
    var pdfDocument: PDFDocument? // 內部使用，Phase 1 直接持有
    public init(id: UUID = UUID(), url: URL? = nil, pdfDocument: PDFDocument? = nil) {
        self.id = id; self.url = url; self.pdfDocument = pdfDocument
    }
}
public struct PDFPageWrapper {
    public let pageIndex: Int
    public var rotation: Int
    var page: PDFPage // 內部持有
    public init(page: PDFPage, pageIndex: Int, rotation: Int = 0) {
        self.page = page; self.pageIndex = pageIndex; self.rotation = rotation
    }
}

import PDFKit

struct PDFUtils {
    static func swapPages(in document: PDFDocument, from: Int, to: Int) {
        guard let page = document.page(at: from) else { return }
        document.removePage(at: from)
        document.insert(page, at: to)
    }
}
import PDFKit
import Foundation

extension DocumentController {

    func saveCurrentDocument() {
        guard !openDocuments.isEmpty else {
            showError("沒有可儲存的文檔")
            return
        }
        let doc = selectedDocument ?? openDocuments[0]
        saveDocument(doc)
    }

    func saveAsCurrentDocument() {
        guard !openDocuments.isEmpty else {
            showError("沒有可儲存為的文檔")
            return
        }
        let doc = selectedDocument ?? openDocuments[0]
        saveAs(doc)
    }

    func deletePage(at index: Int) {
        guard !openDocuments.isEmpty else { return }
        guard let doc = selectedDocument, index >= 0 else { return }
        do {
            try PDFKitEngine.shared.removePage(doc, at: index)
        } catch {
            showError("刪除頁面失敗: \(error.localizedDescription)")
        }
    }

    func rotatePage(at index: Int) {
        guard !openDocuments.isEmpty else { return }
        guard let doc = selectedDocument, index >= 0 else { return }
        do {
            try PDFKitEngine.shared.rotatePage(doc, at: index, rotation: 90)
        } catch {
            showError("旋轉頁面失敗: \(error.localizedDescription)")
        }
    }

    func duplicatePage(at index: Int) {
        guard !openDocuments.isEmpty else { return }
        guard let doc = selectedDocument else { return }
        do {
            if let page = try? PDFKitEngine.shared.getPage(doc, at: index) {
                // 複製頁面邏輯：從 PDFKit 層面新增相同頁面
                if let pdfDoc = doc.pdfDocument {
                    if let pageObj = pdfDoc.page(at: index) {
                        let copy = pageObj  // PDFPage 參考類型，直接複製
                        pdfDoc.insert(copy, at: index + 1)
                    }
                }
            }
        } catch {
            showError("複製頁面失敗: \(error.localizedDescription)")
        }
    }

    private var selectedDocument: PDFDocumentWrapper? {
        openDocuments.first(where: { $0.id == selectedDocumentID }) ?? openDocuments.first
    }

    private var selectedDocumentID: UUID? {
        openDocuments.first?.id
    }
}

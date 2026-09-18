import PDFKit
import Foundation

extension DocumentController {
    func saveCurrentDocument() {
        guard let doc = openDocuments.first(where: { $0.id == selectedDocumentID }) else {
            // Save first document if none selected
            if let first = openDocuments.first {
                saveDocument(first)
            }
            return
        }
        saveDocument(doc)
    }
    
    func saveAsCurrentDocument() {
        guard let doc = openDocuments.first(where: { $0.id == selectedDocumentID }) else {
            if let first = openDocuments.first {
                saveAs(first)
            }
            return
        }
        saveAs(doc)
    }
    
    func deletePage(at index: Int) {
        guard index >= 0, index < getPageCount() else { return }
        
        // Undo registration
        let undoManager = UndoManager.current
        undoManager?.registerUndo(withTarget: self) { target in
            // Reinsert page at original index
        }
        
        do {
            // Get PDFDocument and remove page
            if let doc = openDocuments.first(where: { $0.id == selectedDocumentID }) {
                // For now, mark as not implemented
                throw PDFEngineError.notImplemented
            }
        } catch {
            showError("Failed to delete page: \(error.localizedDescription)")
        }
    }
    
    func rotatePage(at index: Int) {
        guard index >= 0 else { return }
        
        // Undo registration
        let undoManager = UndoManager.current
        undoManager?.registerUndo(withTarget: self) { target in
            // Rotate back
        }
        
        do {
            // Implementation would go here
            throw PDFEngineError.notImplemented
        } catch {
            showError("Failed to rotate page: \(error.localizedDescription)")
        }
    }
    
    func duplicatePage(at index: Int) {
        guard index >= 0 else { return }
        
        // Undo registration
        let undoManager = UndoManager.current
        undoManager?.registerUndo(withTarget: self) { target in
            // Remove duplicated page
        }
        
        // Implementation would go here
    }
    
    private var selectedDocumentID: UUID? {
        // For now, use first document
        return openDocuments.first?.id
    }
    
    private func getPageCount() -> Int {
        return openDocuments.first.map { PDFKitEngine.shared.getPageCount($0) } ?? 0
    }
}
import Foundation
import PDFKit

// MARK: - Page Model

struct Page {
    let index: Int
    let title: String
    let rotation: Int
}

// MARK: - Document State

class DocumentState: ObservableObject {
    @Published var pages: [Page] = []
    @Published var currentPageIndex: Int = 0
    
    // Undo/Redo support
    private var undoStack: [() -> Void] = []
    private var redoStack: [() -> Void] = []
    
    func addUndoAction(_ action: @escaping () -> Void) {
        undoStack.append(action)
        redoStack.removeAll()
    }
    
    func undo() {
        guard !undoStack.isEmpty else { return }
        let action = undoStack.removeLast()
        action()
    }
    
    func redo() {
        guard !redoStack.isEmpty else { return }
        let action = redoStack.removeLast()
        action()
    }
}
import AppKit
import PDFKit

final class UndoManagerAdapter {
    private let undoManager: UndoManager
    
    init(undoManager: UndoManager = UndoManager()) {
        self.undoManager = undoManager
    }
    
    func registerUndo(withTarget target: Any, handler: @escaping (Any) -> Void) {
        undoManager.registerUndo(withTarget: target, handler: handler)
    }
    
    func undo() {
        undoManager.undo()
    }
    
    func redo() {
        undoManager.redo()
    }
    
    var canUndo: Bool {
        undoManager.canUndo
    }
    
    var canRedo: Bool {
        undoManager.canRedo
    }
}
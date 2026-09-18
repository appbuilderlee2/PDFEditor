import Foundation

/// Edit operation types for Undo/Redo
public enum EditOperation {
    case insertText(pageIndex: Int, text: String, position: CGPoint)
    case replaceText(pageIndex: Int, oldText: String, newText: String)
    case deleteText(pageIndex: Int, text: String)
    case highlight(pageIndex: Int, rect: CGRect, color: String)
    case drawFreehand(pageIndex: Int, points: [CGPoint], color: String, lineWidth: CGFloat)
    case addShape(pageIndex: Int, rect: CGRect, type: String)
}

final class UndoManager {
    private var undoStack: [EditOperation] = []
    private var redoStack: [EditOperation] = []
    
    func registerUndo(_ operation: EditOperation) {
        undoStack.append(operation)
        redoStack.removeAll()
    }
    
    func undo() -> EditOperation? {
        guard let op = undoStack.popLast() else { return nil }
        redoStack.append(op)
        return op
    }
    
    func redo() -> EditOperation? {
        guard let op = redoStack.popLast() else { return nil }
        undoStack.append(op)
        return op
    }
    
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var count: Int { undoStack.count }
}

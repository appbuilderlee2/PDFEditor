import Combine
import Foundation

@MainActor
final class UndoManagerAdapter: ObservableObject {
    let undoManager: UndoManager

    init(undoManager: UndoManager = UndoManager()) {
        self.undoManager = undoManager
    }

    func registerUndo<Target: AnyObject>(
        withTarget target: Target,
        actionName: String,
        handler: @escaping (Target) -> Void
    ) {
        undoManager.registerUndo(withTarget: target, handler: handler)
        undoManager.setActionName(actionName)
        objectWillChange.send()
    }

    func undo() {
        guard undoManager.canUndo else { return }
        undoManager.undo()
        objectWillChange.send()
    }

    func redo() {
        guard undoManager.canRedo else { return }
        undoManager.redo()
        objectWillChange.send()
    }

    func removeAllActions() {
        undoManager.removeAllActions()
        objectWillChange.send()
    }

    var canUndo: Bool { undoManager.canUndo }
    var canRedo: Bool { undoManager.canRedo }
    var undoActionName: String { undoManager.undoActionName }
    var redoActionName: String { undoManager.redoActionName }
}

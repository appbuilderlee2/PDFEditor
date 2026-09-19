// PDFEditor — Native macOS PDF Editor
// Apple PDFKit only. Documents stay local unless the user explicitly saves them.

import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

@main
@MainActor
struct PDFEditorApp: App {
    @StateObject private var documentController = DocumentController()

    var body: some Scene {
        WindowGroup("PDF Editor") {
            MainView(documentController: documentController)
                .frame(minWidth: 900, minHeight: 600)
        }
        .commands {
            PDFEditorCommands(documentController: documentController)
        }
    }
}

@MainActor
final class DocumentController: ObservableObject {
    @Published private(set) var activeDocument: PDFDocumentWrapper?
    @Published private(set) var documentState = DocumentState()
    let history = UndoManagerAdapter()

    var undoManager: UndoManager { history.undoManager }
    var hasDocument: Bool { activeDocument != nil }

    func openDocument() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.pdf]

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let document = try PDFKitEngine.shared.openDocument(at: url)
            loadDocument(document)
        } catch {
            showError("Failed to open PDF: \(error.localizedDescription)")
        }
    }

    func loadDocument(_ document: PDFDocumentWrapper, selecting index: Int = 0) {
        activeDocument = document
        history.removeAllActions()
        refreshPages(selecting: index)
    }

    func saveDocument(_ document: PDFDocumentWrapper) {
        guard let url = document.url else {
            saveAs(document)
            return
        }

        do {
            try PDFKitEngine.shared.saveDocument(document, to: url)
            document.isModified = false
            activeDocument = document
        } catch {
            showError("Failed to save: \(error.localizedDescription)")
        }
    }

    func saveAs(_ document: PDFDocumentWrapper) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = document.url?.lastPathComponent ?? "Untitled.pdf"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try PDFKitEngine.shared.saveAs(document, to: url)
            document.url = url
            document.isModified = false
            activeDocument = document
        } catch {
            showError("Failed to save as: \(error.localizedDescription)")
        }
    }

    func selectPage(at index: Int) {
        documentState.selectPage(at: index)
    }

    func refreshPages(selecting selectedIndex: Int? = nil) {
        guard let document = activeDocument else {
            documentState = DocumentState()
            return
        }

        let count = PDFKitEngine.shared.getPageCount(document)
        let pages = (0..<count).map { index in
            let pdfPage = document.pdfDocument?.page(at: index)
            return PDFPageModel(
                index: index,
                title: pdfPage?.label ?? "Page \(index + 1)",
                rotation: pdfPage?.rotation ?? 0
            )
        }

        var state = documentState
        if let selectedIndex {
            state.currentPageIndex = selectedIndex
        }
        state.replacePages(with: pages)
        documentState = state
    }

    func markDocumentModified() {
        guard let document = activeDocument else { return }
        document.isModified = true
        activeDocument = document
    }

    func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.alertStyle = .critical
        alert.runModal()
    }
}

@MainActor
struct PDFEditorCommands: Commands {
    @ObservedObject var documentController: DocumentController
    @ObservedObject private var history: UndoManagerAdapter

    init(documentController: DocumentController) {
        self.documentController = documentController
        self.history = documentController.history
    }

    var body: some Commands {
        CommandGroup(replacing: .undoRedo) {
            Button(history.undoActionName.isEmpty ? "Undo" : "Undo \(history.undoActionName)") {
                history.undo()
            }
            .keyboardShortcut("z")
            .disabled(!history.canUndo)

            Button(history.redoActionName.isEmpty ? "Redo" : "Redo \(history.redoActionName)") {
                history.redo()
            }
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .disabled(!history.canRedo)
        }

        CommandGroup(after: .newItem) {
            Button("Open…") {
                documentController.openDocument()
            }
            .keyboardShortcut("o")
        }

        CommandGroup(replacing: .saveItem) {
            Button("Save") {
                documentController.saveCurrentDocument()
            }
            .keyboardShortcut("s")
            .disabled(!documentController.hasDocument)

            Button("Save As…") {
                documentController.saveAsCurrentDocument()
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
            .disabled(!documentController.hasDocument)
        }
    }
}

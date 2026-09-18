// PDFEditor — Native macOS PDF Editor
// Phase 1: Architecture, native document window, viewer, sidebar, toolbar, page tools.
// License: MIT | Offline-first, privacy-first, open-source.
// Third-party: Apple PDFKit only (no AGPL/PDFium in Phase 1).

import AppKit
import SwiftUI

@main
struct PDFEditorApp: App {
    @StateObject private var documentController = DocumentController()

    var body: some Scene {
        DocumentGroup()
            .commands {
                PDFEditorCommands()
            }
    }
}

// MARK: - Document Controller

@MainActor
final class DocumentController: ObservableObject {
    @Published var openDocuments: [PDFDocumentWrapper] = []
    
    func openDocument() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.pdf]
        
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let doc = try PDFKitEngine.shared.openDocument(at: url)
                self.openDocuments.append(doc)
            } catch {
                self.showError("Failed to open PDF: \(error.localizedDescription)")
            }
        }
    }
    
    func saveDocument(_ doc: PDFDocumentWrapper) {
        guard let url = doc.url else {
            saveAs(doc)
            return
        }
        do {
            try PDFKitEngine.shared.saveDocument(doc, to: url)
        } catch {
            showError("Failed to save: \(error.localizedDescription)")
        }
    }
    
    func saveAs(_ doc: PDFDocumentWrapper) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectory = true
        panel.nameFieldSuffix = "pdf"
        
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try PDFKitEngine.shared.saveAs(doc, to: url)
            } catch {
                self.showError("Failed to save as: \(error.localizedDescription)")
            }
        }
    }
    
    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.alertStyle = .critical
        alert.beginSheet { _ in }
    }
}

// MARK: - Commands

struct PDFEditorCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Open…") {
                // Handled by DocumentController via NSDocument architecture
            }
            .keyboardShortcut("o")
            
            Button("Save") {
                // Handled by document
            }
            .keyboardShortcut("s")
            
            Button("Save As…") {
                // Handled by document
            }
            .keyboardShortcut("S", modifiers: [.command, .shift])
            
            Divider()
            
            Button("Find") {
                // Handled by PDFView
            }
            .keyboardShortcut("f")
            
            Button("Print…") {
                // Handled by NSPrintOperation
            }
            .keyboardShortcut("p")
        }
    }
}
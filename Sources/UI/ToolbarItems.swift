import AppKit
import PDFKit
import SwiftUI

@MainActor
struct ToolbarItems: View {
    @ObservedObject var documentController: DocumentController
    @ObservedObject private var history: UndoManagerAdapter
    let pdfView: PDFView
    @Binding var zoomFactor: Double
    @Binding var displayMode: PDFDisplay
    @State private var searchText = ""
    @State private var searchResults: [PDFSelection] = []
    @State private var searchResultIndex = 0
    @State private var previousSearchText = ""

    init(
        documentController: DocumentController,
        pdfView: PDFView,
        zoomFactor: Binding<Double>,
        displayMode: Binding<PDFDisplay>
    ) {
        self.documentController = documentController
        self.history = documentController.history
        self.pdfView = pdfView
        self._zoomFactor = zoomFactor
        self._displayMode = displayMode
    }

    var body: some View {
        HStack(spacing: 10) {
            Button("Open") { documentController.openDocument() }
                .keyboardShortcut("o")

            Button("Save") { documentController.saveCurrentDocument() }
                .keyboardShortcut("s")
                .disabled(!documentController.hasDocument)

            Button("Save As") { documentController.saveAsCurrentDocument() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(!documentController.hasDocument)

            Divider().frame(height: 20)

            Button {
                history.undo()
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .help(history.undoActionName.isEmpty ? "Undo" : "Undo \(history.undoActionName)")
            .disabled(!history.canUndo)

            Button {
                history.redo()
            } label: {
                Image(systemName: "arrow.uturn.forward")
            }
            .help(history.redoActionName.isEmpty ? "Redo" : "Redo \(history.redoActionName)")
            .disabled(!history.canRedo)

            Divider().frame(height: 20)

            ZoomControls(zoomFactor: $zoomFactor, displayMode: $displayMode)

            Spacer()

            TextField("Find", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 140)
                .onSubmit(findNext)
                .onChange(of: searchText) { _, _ in
                    searchResults = []
                    searchResultIndex = 0
                }

            Button("Find") { findNext() }
                .keyboardShortcut("f")
                .disabled(searchText.isEmpty || pdfView.document == nil)

            Button("Print") {
                pdfView.print(with: NSPrintInfo.shared, autoRotate: true)
            }
            .keyboardShortcut("p")
            .disabled(pdfView.document == nil)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .onChange(of: documentController.activeDocument?.id) { _, _ in
            resetSearchResults()
        }
        .onChange(of: documentController.documentState.pages) { _, _ in
            resetSearchResults()
        }
    }

    private func resetSearchResults() {
        searchResults = []
        searchResultIndex = 0
        previousSearchText = ""
    }

    private func findNext() {
        guard !searchText.isEmpty,
              let document = pdfView.document else { return }

        if searchResults.isEmpty || previousSearchText != searchText {
            searchResults = document.findString(searchText, withOptions: .caseInsensitive)
            searchResultIndex = 0
            previousSearchText = searchText
        } else {
            searchResultIndex = (searchResultIndex + 1) % searchResults.count
        }

        guard !searchResults.isEmpty else {
            NSSound.beep()
            return
        }

        let selection = searchResults[searchResultIndex]
        pdfView.setCurrentSelection(selection, animate: true)
        pdfView.go(to: selection)
    }
}

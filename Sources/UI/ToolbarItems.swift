import SwiftUI
import PDFKit

struct ToolbarItems: View {
    @ObservedObject var documentController: DocumentController
    @Binding var zoomFactor: Double
    @Binding var displayMode: PDFDisplay

    var body: some View {
        HStack {
            Button("Open") {
                documentController.openDocument()
            }
            .keyboardShortcut("o")

            Button("Save") {
                documentController.saveCurrentDocument()
            }
            .keyboardShortcut("s")

            Button("Save As") {
                documentController.saveAsCurrentDocument()
            }
            .keyboardShortcut("S", modifiers: [.command, .shift])

            Divider()

            ZoomControls(zoomFactor: $zoomFactor, displayMode: $displayMode)

            Spacer()

            Button("Find") {
                // PDFView search functionality
            }
            .keyboardShortcut("f")

            Button("Print") {
                // NSPrintOperation
            }
            .keyboardShortcut("p")
        }
        .padding(.horizontal, 6)
    }
}

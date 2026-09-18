import SwiftUI

struct ToolbarItems: View {
    @ObservedObject var documentController: DocumentController
    @Binding var zoomFactor: Double
    @Binding var displayMode: PDFDisplayMode

    var body: some View {
        Toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Open") {
                    documentController.openDocument()
                }
                .keyboardShortcut("o")
            }
            
            ToolbarItem(placement: .primaryAction) {
                Button("Save") {
                    documentController.saveCurrentDocument()
                }
                .keyboardShortcut("s")
            }
            
            ToolbarItem(placement: .primaryAction) {
                Button("Save As") {
                    documentController.saveAsCurrentDocument()
                }
                .keyboardShortcut("S", modifiers: [.command, .shift])
            }
            
            ToolbarItem(placement: .primaryAction) {
                Divider()
            }
            
            ToolbarItem(placement: .primaryAction) {
                ZoomControls(zoomFactor: $zoomFactor, displayMode: $displayMode)
            }
            
            ToolbarItem(placement: .primaryAction) {
                Button("Find") {
                    // PDFView search functionality
                }
                .keyboardShortcut("f")
            }
            
            ToolbarItem(placement: .primaryAction) {
                Button("Print") {
                    // NSPrintOperation
                }
                .keyboardShortcut("p")
            }
        }
    }
}

struct ZoomControls: View {
    @Binding var zoomFactor: Double
    @Binding var displayMode: PDFDisplayMode

    var body: some View {
        HStack(spacing: 4) {
            Button(action: { zoomFactor *= 0.8 }) {
                Image(systemName: "minus")
            }
            .buttonStyle(BorderlessButtonStyle())
            
            Text(String(format: "%.0f%%", zoomFactor * 100))
                .font(.system(size: 11))
                .frame(minWidth: 40)
            
            Button(action: { zoomFactor *= 1.25 }) {
                Image(systemName: "plus")
            }
            .buttonStyle(BorderlessButtonStyle())
            
            Divider()
            
            Button("Fit Width") {
                displayMode = .fitWidth
            }
            .buttonStyle(BorderlessButtonStyle())
            
            Button("Fit Page") {
                displayMode = .fitPage
            }
            .buttonStyle(BorderlessButtonStyle())
            
            Button("100%") {
                displayMode = .singlePageContinuous
                zoomFactor = 1.0
            }
            .buttonStyle(BorderlessButtonStyle())
        }
        .padding(.horizontal, 6)
    }
}

enum PDFDisplayMode {
    case singlePage
    case singlePageContinuous
    case twoPage
    case twoPageSpread
    case fitWidth
    case fitPage
}
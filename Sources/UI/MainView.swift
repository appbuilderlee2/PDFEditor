import SwiftUI
import PDFKit

struct MainView: View {
    @ObservedObject var documentController: DocumentController
    @State private var selectedPageIndex: Int = 0
    @State private var zoomFactor: Double = 1.0
    @State private var displayMode: PDFDisplay = .singlePage
    @State private var pdfView = PDFView()

    var body: some View {
        HStack(spacing: 0) {
            SidebarView(
                documentController: documentController,
                selectedPageIndex: $selectedPageIndex,
                pdfView: $pdfView
            )

            Divider()
                .frame(width: 1)
                .background(Color(nsColor: NSColor.separatorColor))

            VStack(spacing: 0) {
                // Toolbar
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
                        .frame(height: 20)

                    ZoomControls(zoomFactor: $zoomFactor, displayMode: $displayMode)

                    Button("Find") {
                        // PDFView search functionality
                    }
                    .keyboardShortcut("f")

                    Button("Print") {
                        // NSPrintOperation
                    }
                    .keyboardShortcut("p")
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color(nsColor: NSColor.toolbarBackgroundColor))

                Divider()
                    .frame(height: 1)

                // PDF View
                ZStack {
                    PDFViewRepresentable(pdfView: pdfView)
                        .background(Color(nsColor: NSColor.backgroundColor))

                    // Page number display
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            Text("Page \(selectedPageIndex + 1)")
                                .font(.system(size: 12, weight: .medium))
                                .padding(8)
                                .background(Color.black.opacity(0.6))
                                .foregroundColor(.white)
                                .clipShape(Circle())
                        }
                        .padding(.trailing, 16)
                        .padding(.bottom, 16)
                    }
                }
            }
        }
        .onAppear {
            configurePDFView()
        }
        .onChange(of: displayMode) { mode in
            applyDisplayMode(mode)
        }
        .onChange(of: zoomFactor) { factor in
            pdfView.magnification = factor
        }
    }

    private func configurePDFView() {
        pdfView.autoScales = true
        pdfView.displayMode = .singlePage
        pdfView.displayDirection = .vertical
        pdfView.allowsDocumentInteraction = true
        pdfView.allowsDragging = true
    }

    private func applyDisplayMode(_ mode: PDFDisplay) {
        switch mode {
        case .singlePage:
            pdfView.displayMode = .singlePage
        case .singlePageContinuous:
            pdfView.displayMode = .singlePageContinuous
        case .twoPage:
            pdfView.displayMode = .twoPage
        case .twoPageContinuous:
            pdfView.displayMode = .twoPageContinuous
        case .fitWidth:
            pdfView.autoScales = true
        case .fitPage:
            pdfView.autoScales = true
        }
    }
}

struct PDFViewRepresentable: NSViewRepresentable {
    let pdfView: PDFView

    func makeNSView(context: Context) -> PDFView {
        return pdfView
    }

    func updateNSView(_ nsView: PDFView, context: Context) {}
}

enum PDFDisplay {
    case singlePage
    case singlePageContinuous
    case twoPage
    case twoPageContinuous
    case fitWidth
    case fitPage
}

struct ZoomControls: View {
    @Binding var zoomFactor: Double
    @Binding var displayMode: PDFDisplay

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

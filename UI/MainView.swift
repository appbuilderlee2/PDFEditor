import SwiftUI
import PDFKit

struct MainView: View {
    @ObservedObject var documentController: DocumentController
    @State private var selectedPageIndex: Int = 0
    @State private var zoomFactor: Double = 1.0
    @State private var displayMode: PDFDisplayMode = .singlePage
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
                ToolbarItems(
                    documentController: documentController,
                    zoomFactor: $zoomFactor,
                    displayMode: $displayMode
                )
                
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
    }

    private func configurePDFView() {
        pdfView.autoScales = true
        pdfView.displayMode = .singlePage
        pdfView.displayDirection = .vertical
        pdfView.usePageViewController(true, withViewOptions: [:])
    }
}

struct PDFViewRepresentable: NSViewRepresentable {
    let pdfView: PDFView

    func makeNSView(context: Context) -> PDFView {
        return pdfView
    }

    func updateNSView(_ nsView: PDFView, context: Context) {}
}
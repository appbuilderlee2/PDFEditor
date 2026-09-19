import Combine
import PDFKit
import SwiftUI

@MainActor
struct MainView: View {
    @ObservedObject var documentController: DocumentController
    @State private var zoomFactor = 1.0
    @State private var displayMode: PDFDisplay = .singlePageContinuous
    @State private var pdfView = PDFView()

    var body: some View {
        HStack(spacing: 0) {
            SidebarView(documentController: documentController, pdfView: $pdfView)

            Divider()

            VStack(spacing: 0) {
                ToolbarItems(
                    documentController: documentController,
                    pdfView: pdfView,
                    zoomFactor: $zoomFactor,
                    displayMode: $displayMode
                )
                .padding(.vertical, 6)
                .background(Color(nsColor: .windowBackgroundColor))

                Divider()

                ZStack {
                    PDFViewRepresentable(pdfView: pdfView)
                        .background(Color(nsColor: .controlBackgroundColor))

                    if documentController.activeDocument == nil {
                        ContentUnavailableView(
                            "Open a PDF",
                            systemImage: "doc.richtext",
                            description: Text("Choose Open to start viewing and editing pages.")
                        )
                    } else if !documentController.documentState.pages.isEmpty {
                        pageNumberBadge
                    }
                }
            }
        }
        .onAppear {
            configurePDFView()
            synchronizeDocument()
        }
        .onChange(of: documentController.activeDocument?.id) { _, _ in
            synchronizeDocument()
        }
        .onChange(of: documentController.documentState.pages) { _, _ in
            synchronizeDocument()
        }
        .onChange(of: documentController.documentState.currentPageIndex) { _, index in
            goToPage(at: index)
        }
        .onChange(of: displayMode) { _, mode in
            applyDisplayMode(mode)
        }
        .onChange(of: zoomFactor) { _, factor in
            guard displayMode != .fitPage else { return }
            pdfView.autoScales = false
            pdfView.scaleFactor = factor
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: Notification.Name.PDFViewPageChanged,
                object: pdfView
            )
        ) { _ in
            synchronizeSelectionFromPDFView()
        }
    }

    private var pageNumberBadge: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                Text("Page \(documentController.documentState.currentPageIndex + 1) of \(documentController.documentState.pages.count)")
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.65), in: Capsule())
                    .foregroundStyle(.white)
            }
            .padding(16)
        }
        .allowsHitTesting(false)
    }

    private func configurePDFView() {
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.displaysPageBreaks = true
        pdfView.allowsDragging = false
    }

    private func synchronizeDocument() {
        let selectedIndex = documentController.documentState.currentPageIndex
        let document = documentController.activeDocument?.pdfDocument
        if pdfView.document !== document {
            pdfView.document = document
        } else {
            pdfView.layoutDocumentView()
        }
        goToPage(at: selectedIndex)
    }

    private func goToPage(at index: Int) {
        guard let page = pdfView.document?.page(at: index) else { return }
        pdfView.go(to: page)
    }

    private func synchronizeSelectionFromPDFView() {
        guard let document = pdfView.document,
              let page = pdfView.currentPage else { return }
        let index = document.index(for: page)
        guard index >= 0,
              index != documentController.documentState.currentPageIndex else { return }
        documentController.selectPage(at: index)
    }

    private func applyDisplayMode(_ mode: PDFDisplay) {
        switch mode {
        case .singlePage:
            pdfView.displayMode = .singlePage
            pdfView.autoScales = false
        case .singlePageContinuous:
            pdfView.displayMode = .singlePageContinuous
            pdfView.autoScales = false
        case .twoPage:
            pdfView.displayMode = .twoUp
            pdfView.autoScales = false
        case .twoPageContinuous:
            pdfView.displayMode = .twoUpContinuous
            pdfView.autoScales = false
        case .fitPage:
            pdfView.autoScales = true
            zoomFactor = pdfView.scaleFactor
        }
    }
}

@MainActor
struct PDFViewRepresentable: NSViewRepresentable {
    let pdfView: PDFView

    func makeNSView(context: Context) -> PDFView { pdfView }

    func updateNSView(_ nsView: PDFView, context: Context) {
        nsView.needsLayout = true
    }
}

enum PDFDisplay: Equatable {
    case singlePage
    case singlePageContinuous
    case twoPage
    case twoPageContinuous
    case fitPage
}

struct ZoomControls: View {
    @Binding var zoomFactor: Double
    @Binding var displayMode: PDFDisplay

    var body: some View {
        HStack(spacing: 4) {
            Button {
                displayMode = .singlePageContinuous
                zoomFactor = max(0.1, zoomFactor * 0.8)
            } label: {
                Image(systemName: "minus")
            }
            .help("Zoom Out")

            Text(zoomFactor, format: .percent.precision(.fractionLength(0)))
                .font(.system(size: 11, design: .monospaced))
                .frame(minWidth: 44)

            Button {
                displayMode = .singlePageContinuous
                zoomFactor = min(10, zoomFactor * 1.25)
            } label: {
                Image(systemName: "plus")
            }
            .help("Zoom In")

            Divider().frame(height: 18)

            Button("Fit Page") { displayMode = .fitPage }
            Button("100%") {
                displayMode = .singlePageContinuous
                zoomFactor = 1
            }
        }
        .buttonStyle(.borderless)
    }
}

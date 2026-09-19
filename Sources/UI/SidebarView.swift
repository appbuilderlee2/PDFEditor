import PDFKit
import SwiftUI

@MainActor
struct SidebarView: View {
    @ObservedObject var documentController: DocumentController
    @Binding var pdfView: PDFView

    var body: some View {
        Group {
            if let document = documentController.activeDocument {
                List {
                    ForEach(documentController.documentState.pages) { page in
                        SidebarPageRow(
                            document: document,
                            page: page,
                            isSelected: documentController.documentState.currentPageIndex == page.index,
                            canMoveUp: page.index > 0,
                            canMoveDown: page.index + 1 < documentController.documentState.pages.count,
                            onSelect: { select(page.index, in: document) },
                            onDelete: { documentController.deletePage(at: page.index) },
                            onRotate: { documentController.rotatePage(at: page.index) },
                            onDuplicate: { documentController.duplicatePage(at: page.index) },
                            onMoveUp: {
                                documentController.reorderPage(from: page.index, to: page.index - 1)
                            },
                            onMoveDown: {
                                documentController.reorderPage(from: page.index, to: page.index + 1)
                            }
                        )
                    }
                    .onMove(perform: documentController.movePage)
                }
                .listStyle(.sidebar)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "sidebar.left")
                        .font(.title2)
                    Text("No Pages")
                        .font(.headline)
                    Text("Open a PDF to view its pages.")
                        .font(.caption)
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(.secondary)
                .padding()
            }
        }
        .frame(minWidth: 180, idealWidth: 220, maxWidth: 280)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func select(_ index: Int, in document: PDFDocumentWrapper) {
        documentController.selectPage(at: index)
        guard let page = document.pdfDocument?.page(at: index) else { return }
        pdfView.go(to: page)
    }
}

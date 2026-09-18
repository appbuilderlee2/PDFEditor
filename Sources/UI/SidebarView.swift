import SwiftUI
import PDFKit

struct SidebarView: View {
    @ObservedObject var documentController: DocumentController
    @Binding var selectedPageIndex: Int
    @Binding var pdfView: PDFView?

    var body: some View {
        ScrollView(.vertical) {
            VStack(spacing: 8) {
                ForEach(Array(documentController.openDocuments.enumerated()), id: \.element.id) { index, doc in
                    SidebarPageRow(
                        document: doc,
                        pageIndex: index,
                        isSelected: selectedPageIndex == index,
                        pdfView: $pdfView,
                        onSelect: {
                            selectedPageIndex = index
                            if let page = doc.pdfDocument?.page(at: index) {
                                pdfView?.goToPage(page)
                            }
                        },
                        onDelete: {
                            documentController.deletePage(at: index)
                        },
                        onRotate: {
                            documentController.rotatePage(at: index)
                        },
                        onDuplicate: {
                            documentController.duplicatePage(at: index)
                        }
                    )
                }
            }
        }
        .frame(minWidth: 120, maxWidth: 200)
        .background(Color(NSColor.windowBackgroundColor))
        .border(Color(nsColor: NSColor.separatorColor), width: 1)
    }
}

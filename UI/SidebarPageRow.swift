import SwiftUI
import PDFKit

struct SidebarPageRow: View {
    let document: PDFDocumentWrapper
    let pageIndex: Int
    let isSelected: Bool
    @Binding var pdfView: PDFView?
    let onSelect: () -> Void
    let onDelete: () -> Void
    let onRotate: () -> Void
    let onDuplicate: () -> Void

    @State private var thumbnailImage: NSImage?

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                if let image = thumbnailImage {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 50, height: 65)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                } else {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.gray.opacity(0.3))
                        .frame(width: 50, height: 65)
                        .overlay(Text("P\(pageIndex + 1)").font(.caption))
                }
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("Page \(pageIndex + 1)")
                        .font(.system(size: 11, weight: .medium))
                    Text(document.url?.lastPathComponent ?? "Unknown")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                // Quick action buttons
                Button(action: { onRotate() }) {
                    Image(systemName: "rotate.right")
                        .font(.system(size: 10))
                }
                .buttonStyle(BorderlessButtonStyle())
                
                Button(action: { onDelete() }) {
                    Image(systemName: "trash")
                        .font(.system(size: 10))
                }
                .buttonStyle(BorderlessButtonStyle())
            }
            .padding(6)
            .background(isSelected ? Color.blue.opacity(0.15) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onAppear {
            loadThumbnail()
        }
    }

    private func loadThumbnail() {
        guard let pdfView = pdfView,
              let page = pdfView.document?.page(at: pageIndex) else { return }
        let size = CGSize(width: 50, height: 65)
        thumbnailImage = page.thumbnail(of: size, for: .cropBox)
    }
}
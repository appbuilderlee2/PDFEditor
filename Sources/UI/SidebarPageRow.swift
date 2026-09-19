import PDFKit
import SwiftUI

@MainActor
struct SidebarPageRow: View {
    let document: PDFDocumentWrapper
    let page: PDFPageModel
    let isSelected: Bool
    let canMoveUp: Bool
    let canMoveDown: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void
    let onRotate: () -> Void
    let onDuplicate: () -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                thumbnail

                VStack(alignment: .leading, spacing: 4) {
                    Text(page.title)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)

                    Text("Page \(page.index + 1)")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if page.rotation != 0 {
                        Label("\(page.rotation)°", systemImage: "rotate.right")
                            .font(.caption2)
                            .foregroundStyle(.blue)
                    }
                }

                Spacer(minLength: 0)
            }

            HStack(spacing: 10) {
                Button(action: onMoveUp) { Image(systemName: "arrow.up") }
                    .disabled(!canMoveUp)
                    .help("Move Page Up")
                Button(action: onMoveDown) { Image(systemName: "arrow.down") }
                    .disabled(!canMoveDown)
                    .help("Move Page Down")
                Button(action: onRotate) { Image(systemName: "rotate.right") }
                    .help("Rotate Page")
                Button(action: onDuplicate) { Image(systemName: "doc.on.doc") }
                    .help("Duplicate Page")
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .help("Delete Page")
            }
            .buttonStyle(.borderless)
        }
        .padding(8)
        .background(isSelected ? Color.accentColor.opacity(0.14) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let pdfPage = document.pdfDocument?.page(at: page.index) {
            Image(nsImage: pdfPage.thumbnail(of: CGSize(width: 96, height: 120), for: .cropBox))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 72, height: 90)
                .background(.white)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
        } else {
            RoundedRectangle(cornerRadius: 4)
                .fill(.quaternary)
                .frame(width: 72, height: 90)
        }
    }
}

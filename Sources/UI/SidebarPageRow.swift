import SwiftUI
import PDFKit

struct SidebarPageRow: View {
    let document: PDFDocumentWrapper
    let pageIndex: Int
    let isSelected: Bool
    @Binding var pdfView: PDFView?
    var onSelect: () -> Void
    var onDelete: () -> Void
    var onRotate: () -> Void
    var onDuplicate: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // 縮圖
            if let page = document.pdfDocument?.page(at: pageIndex) {
                let thumb = page.thumbnail(of: CGSize(width: 100, height: 120), for: .mediaBox)
                Image(nsImage: thumb)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 80, height: 96)
                    .cornerRadius(6)
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.gray.opacity(0.2))
                    .frame(width: 80, height: 96)
            }

            // 頁面資訊
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("頁 \(pageIndex + 1)")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.primary)

                    if document.rotation != 0 {
                        Image(systemName: ".rotate.90")
                            .font(.system(size: 10))
                            .foregroundColor(.blue)
                    }
                }

                if let page = document.pdfDocument?.page(at: pageIndex) {
                    let text = page.string?.prefix(30) ?? ""
                    Text(String(text) + (page.string?.count ?? 0 > 30 ? "..." : ""))
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            // 動作按鈕
            HStack(spacing: 4) {
                Button(action: onSelect) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10))
                        .foregroundColor(.blue)
                }
                .buttonStyle(PlainButtonStyle())

                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 10))
                        .foregroundColor(.red)
                }
                .buttonStyle(PlainButtonStyle())

                Button(action: onRotate) {
                    Image(systemName: ".rotate.3d")
                        .font(.system(size: 10))
                        .foregroundColor(.orange)
                }
                .buttonStyle(PlainButtonStyle())

                Button(action: onDuplicate) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 10))
                        .foregroundColor(.green)
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
        .padding(8)
        .background(isSelected ? Color.blue.opacity(0.1) : Color.clear)
        .cornerRadius(8)
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
    }
}
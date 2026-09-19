import Foundation

/// Lightweight, value-semantic page metadata for sidebar and list rendering.
/// The live PDFPage remains owned by PDFPageWrapper/PDFDocumentWrapper.
public struct PDFPageModel: Identifiable, Hashable, Sendable {
    public let id: UUID
    public var index: Int
    public var title: String
    public var rotation: Int

    public init(
        id: UUID = UUID(),
        index: Int,
        title: String? = nil,
        rotation: Int = 0
    ) {
        self.id = id
        self.index = index
        self.title = title ?? "Page \(index + 1)"
        self.rotation = rotation
    }
}

import CoreGraphics
import Foundation

// MARK: - Annotation Model

public struct AnnotationModel: Identifiable, Sendable {
    public let id: UUID
    public let type: AnnotationType
    public let rect: CGRect
    public var text: String
    public var color: String
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        type: AnnotationType,
        rect: CGRect,
        text: String,
        color: String = "#FFFF00",
        createdAt: Date = Date()
    ) {
        self.id = id
        self.type = type
        self.rect = rect
        self.text = text
        self.color = color
        self.createdAt = createdAt
    }
}

public enum AnnotationType: Sendable {
    case highlight
    case underline
    case strikeThrough
    case stickyNote
    case freehand
    case shape(rect: Bool, circle: Bool, arrow: Bool)
}

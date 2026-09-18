// MARK: - Page Model（支援內容編輯狀態）

public struct Page {
    let index: Int
    let title: String
    let rotation: Int
}

// MARK: - Annotation Model（支持高亮、註記、自由手繪）

public struct AnnotationModel {
    public let id: UUID
    public let type: AnnotationType
    public let rect: CGRect
    public var text: String
    public var color: String // HEX
    public var createdAt: Date

    public init(id: UUID = UUID(), type: AnnotationType, rect: CGRect, text: String, color: String = "#FFFF00", createdAt: Date = Date()) {
        self.id = id
        self.type = type
        self.rect = rect
        self.text = text
        self.color = color
        self.createdAt = createdAt
    }
}

public enum AnnotationType {
    case highlight
    case underline
    case strikeThrough
    case stickyNote
    case freehand
    case shape(rect: Bool, circle: Bool, arrow: Bool)
}

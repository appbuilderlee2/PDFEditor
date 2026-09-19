import CoreGraphics
import Foundation

/// A deliberately small representation of content-stream operators currently
/// recognized by the Phase 2 reader. It is not a lossless PDF syntax tree.
public enum PDFContentCommand: CustomStringConvertible, Sendable {
    case beginText
    case endText
    case textMatrix
    case textPosition
    case showText(String)
    case rect(CGFloat, CGFloat, CGFloat, CGFloat)
    case fill
    case stroke
    case setLineWidth(CGFloat)
    case setFont(String, CGFloat)
    case saveState
    case restoreState

    public var description: String {
        switch self {
        case .beginText: return "BT"
        case .endText: return "ET"
        case .textMatrix: return "Tm"
        case .textPosition: return "Td"
        case .showText(let string): return "Tj(\(string))"
        case .rect(let x, let y, let width, let height):
            return "re(\(x),\(y),\(width),\(height))"
        case .fill: return "f"
        case .stroke: return "S"
        case .setLineWidth(let width): return "w(\(width))"
        case .setFont(let font, let size): return "font(\(font) \(size)pt)"
        case .saveState: return "q"
        case .restoreState: return "Q"
        }
    }
}

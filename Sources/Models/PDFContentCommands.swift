// MARK: - PDF Content Stream Commands

/// PDF content stream 中的繪圖/文字指令（BT/ET, Tm, Td, re 等）
public enum PDFContentCommand: CustomStringConvertible {
    case beginText      // BT
    case endText        // ET
    case textMatrix     // Tm
    case textPosition   // Td / TD
    case showText(String) // Tj / TJ
    case rect(CGFloat, CGFloat, CGFloat, CGFloat) // re
    case fill          // f / F
    case stroke        // S / s
    case setLineWidth(CGFloat)
    case setFont(String, CGFloat)
    case saveState     // q
    case restoreState  // Q

    public var description: String {
        switch self {
        case .beginText: return "BT"
        case .endText:   return "ET"
        case .textMatrix: return "Tm"
        case .textPosition: return "Td"
        case .showText(let s): return "Tj(\(s))"
        case .rect(let x, let y, let w, let h): return "re(\(x),\(y),\(w),\(h))"
        case .fill: return "f"
        case .stroke: return "S"
        case .setLineWidth(let w): return "w(\(w))"
        case .setFont(let f, let s): return "font(\(f) \(s)pt)"
        case .saveState: return "q"
        case .restoreState: return "Q"
        }
    }
}

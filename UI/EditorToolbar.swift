import SwiftUI

final class ToolbarState: ObservableObject {
    @Published var activeTool: ToolbarTool = .select
    
    enum ToolbarTool: String, CaseIterable {
        case select = "Cursor"
        case highlight = "Highlighter"
        case underline = "Underline"
        case draw = "Draw"
        case shape = "Shape"
        case text = "Text"
        
        var icon: String {
            switch self {
            case .select:    return "cursorarrow"
            case .highlight: return "highlighter"
            case .underline: return "underline"
            case .draw:      return "pencil"
            case .shape:     return "rectangle"
            case .text:      return "textformat"
            }
        }
    }
}

struct EditorToolbar: View {
    @ObservedObject var toolbarState: ToolbarState
    @Binding var highlightColor: TextSelectionState.HighlightColor
    
    var body: some View {
        HStack(spacing: 4) {
            // Tool buttons
            ForEach(ToolbarState.ToolbarTool.allCases, id: \.self) { tool in
                Button(action: {
                    toolbarState.activeTool = tool
                }) {
                    Image(systemName: tool.icon)
                        .foregroundColor(toolbarState.activeTool == tool ? .accentColor : .secondary)
                }
                .buttonStyle(.bordered)
                .help(tool.rawValue)
            }
            
            Divider()
            
            // Color picker for highlights
            ForEach(TextSelectionState.HighlightColor.allCases, id: \.self) { color in
                Button(action: {
                    highlightColor = color
                }) {
                    Circle()
                        .fill(Color(color.rawValue) ?? .yellow)
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.bordered)
                .help(color.rawValue)
            }
        }
        .padding(.horizontal, 6)
    }
}

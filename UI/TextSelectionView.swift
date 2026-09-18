import SwiftUI
import PDFKit
import CoreGraphics

// MARK: - Text Selection State

final class TextSelectionState: ObservableObject {
    @Published var isSelecting: Bool = false
    @Published var selectedText: String = ""
    @Published var selectionRects: [CGRect] = []
    @Published var activePageIndex: Int = 0
    @Published var highlightColor: HighlightColor = .yellow
    
    enum HighlightColor: String, CaseIterable {
        case yellow = "yellow"
        case blue = "blue"
        case green = "green"
        case orange = "orange"
        case gray = "gray"
        
        var cgColor: CGColor {
            switch self {
            case .yellow: return CGColor(red: 1, green: 1, blue: 0, alpha: 0.4)
            case .blue:   return CGColor(red: 0, green: 0, blue: 1, alpha: 0.3)
            case .green:  return CGColor(red: 0, green: 1, blue: 0, alpha: 0.3)
            case .orange: return CGColor(red: 1, green: 0.5, blue: 0, alpha: 0.4)
            case .gray:   return CGColor(red: 0.7, green: 0.7, blue: 0.7, alpha: 0.4)
            }
        }
    }
}

// MARK: - Highlight View (PDFKit Annotation Overlay - temporary until content stream implementation)

struct HighlightView: View {
    let rect: CGRect
    let color: CGColor
    
    var body: some View {
        Rectangle()
            .fill(Color(cgColor: color) ?? Color.yellow.opacity(0.4))
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
    }
}

// MARK: - Text Selection Overlay

struct TextSelectionOverlay: View {
    @Binding var selectionState: TextSelectionState
    @Binding var pdfView: PDFView?
    var pageIndex: Int
    
    var body: some View {
        ZStack {
            // Highlight rectangles on selected text
            ForEach(selectionState.selectionRects.indices, id: \.self) { idx in
                HighlightView(rect: selectionState.selectionRects[idx], color: selectionState.highlightColor.cgColor)
            }
            
            // Selection actions
            if !selectionState.selectedText.isEmpty {
                HStack(spacing: 4) {
                    Button("Highlight") {
                        addHighlight()
                    }
                    .buttonStyle(.bordered)
                    
                    Button("Copy") {
                        NSPasteboard.general.setString(selectionState.selectedText, forType: .string)
                    }
                    .buttonStyle(.bordered)
                    
                    Button("Cancel") {
                        clearSelection()
                    }
                    .buttonStyle(.bordered)
                }
                .padding(6)
                .background(Color(NSColor.windowBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .shadow(radius: 5)
            }
        }
    }
    
    private func addHighlight() {
        guard let doc = getSelectedDocument() else { return }
        do {
            try PDFContentEngine.shared.addHighlight(
                document: doc,
                pageIndex: pageIndex,
                rect: selectionState.selectionRects.first ?? CGRect.zero,
                color: selectionState.highlightColor.cgColor
            )
            clearSelection()
        } catch {
            print("Highlight error: \(error)")
        }
    }
    
    private func clearSelection() {
        selectionState.isSelecting = false
        selectionState.selectedText = ""
        selectionState.selectionRects = []
    }
    
    private func getSelectedDocument() -> PDFDocumentWrapper? {
        // Will be injected via environment or binding
        return nil
    }
}

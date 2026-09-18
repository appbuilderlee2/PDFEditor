import Foundation
import PDFKit
import CoreGraphics

// MARK: - PDFPage Selection Extension

extension PDFPage {
    /// Find text selection rectangles on the page
    func selectionRects(for text: String) -> [CGRect] {
        // Use PDFKit's built-in search
        guard let selection = self.selection(for: text) else { return [] }
        
        var rects: [CGRect] = []
        let count = selection.numberOfRects
        for i in 0..<count {
            rects.append(selection.rect(at: i))
        }
        return rects
    }
}

// MARK: - Text Selection Helper

final class TextSelectionHelper {
    private let parser = PDFContentStreamParser.shared
    
    /// Extract text with position info from content stream
    func extractTextWithPositions(from page: PDFPage) throws -> [(text: String, rect: CGRect)] {
        let commands = try parser.parse(page: page)
        var results: [(String, CGRect)] = []
        var currentRect = CGRect.zero
        
        for cmd in commands {
            switch cmd {
            case .beginText:
                currentRect = CGRect.zero
            case .showText(let text):
                results.append((text, currentRect))
            case .textMatrix(let matrix):
                // Parse Tm matrix for position
                break
            default:
                break
            }
        }
        
        return results
    }
    
    /// Find all occurrences of text on page with their rectangles
    func findText(_ searchText: String, in page: PDFPage) -> [CGRect] {
        return page.selectionRects(for: searchText)
    }
}

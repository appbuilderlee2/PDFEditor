import PDFKit

@MainActor
enum PDFUtils {
    static func normalizedRotation(_ rotation: Int) -> Int {
        let value = rotation % 360
        return value >= 0 ? value : value + 360
    }

    static func insertPage(_ page: PDFPage, in document: PDFDocument, at index: Int) {
        document.insert(page, at: min(max(index, 0), document.pageCount))
    }

    static func reorderDestination(from source: Int, proposedDestination: Int) -> Int {
        proposedDestination > source ? proposedDestination - 1 : proposedDestination
    }
}

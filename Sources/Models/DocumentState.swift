import Foundation

struct DocumentState: Equatable {
    var pages: [PDFPageModel] = []
    var currentPageIndex = 0

    mutating func replacePages(with newPages: [PDFPageModel]) {
        pages = newPages
        currentPageIndex = Self.clampedPageIndex(currentPageIndex, pageCount: newPages.count)
    }

    mutating func selectPage(at index: Int) {
        currentPageIndex = Self.clampedPageIndex(index, pageCount: pages.count)
    }

    private static func clampedPageIndex(_ index: Int, pageCount: Int) -> Int {
        guard pageCount > 0 else { return 0 }
        return min(max(index, 0), pageCount - 1)
    }
}

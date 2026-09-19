import PDFKit

@MainActor
extension DocumentController {
    func saveCurrentDocument() {
        guard let document = activeDocument else {
            showError("There is no document to save.")
            return
        }
        saveDocument(document)
    }

    func saveAsCurrentDocument() {
        guard let document = activeDocument else {
            showError("There is no document to save.")
            return
        }
        saveAs(document)
    }

    func deletePage(at index: Int) {
        performPageDeletion(at: index, actionName: "Delete Page")
    }

    func rotatePage(at index: Int) {
        guard let document = activeDocument,
              let page = document.pdfDocument?.page(at: index) else { return }
        let newRotation = PDFUtils.normalizedRotation(page.rotation + 90)
        performRotation(at: index, rotation: newRotation, actionName: "Rotate Page")
    }

    func duplicatePage(at index: Int) {
        guard let document = activeDocument,
              index >= 0,
              index < PDFKitEngine.shared.getPageCount(document) else { return }

        do {
            try PDFKitEngine.shared.duplicatePage(document, at: index)
            let duplicateIndex = index + 1
            finishPageMutation(selecting: duplicateIndex)
            history.registerUndo(withTarget: self, actionName: "Duplicate Page") { target in
                target.performPageDeletion(at: duplicateIndex, actionName: "Duplicate Page")
            }
        } catch {
            showError("Failed to duplicate page: \(error.localizedDescription)")
        }
    }

    func reorderPage(from sourceIndex: Int, to destinationIndex: Int) {
        performPageReorder(from: sourceIndex, to: destinationIndex, actionName: "Move Page")
    }

    func movePage(fromOffsets offsets: IndexSet, toOffset proposedDestination: Int) {
        guard offsets.count == 1, let source = offsets.first else { return }
        let destination = PDFUtils.reorderDestination(
            from: source,
            proposedDestination: proposedDestination
        )
        reorderPage(from: source, to: destination)
    }

    private func performPageDeletion(at index: Int, actionName: String) {
        guard let document = activeDocument,
              let pdfDocument = document.pdfDocument,
              index >= 0,
              index < pdfDocument.pageCount,
              let removedPage = pdfDocument.page(at: index) else { return }

        do {
            try PDFKitEngine.shared.removePage(document, at: index)
            finishPageMutation(selecting: index)
            history.registerUndo(withTarget: self, actionName: actionName) { target in
                target.restorePage(removedPage, at: index, actionName: actionName)
            }
        } catch {
            showError("Failed to delete page: \(error.localizedDescription)")
        }
    }

    private func restorePage(_ page: PDFPage, at index: Int, actionName: String) {
        guard let document = activeDocument,
              let pdfDocument = document.pdfDocument else { return }

        PDFUtils.insertPage(page, in: pdfDocument, at: index)
        finishPageMutation(selecting: index)
        history.registerUndo(withTarget: self, actionName: actionName) { target in
            target.performPageDeletion(at: index, actionName: actionName)
        }
    }

    private func performRotation(at index: Int, rotation: Int, actionName: String) {
        guard let document = activeDocument,
              let page = document.pdfDocument?.page(at: index) else { return }
        let previousRotation = PDFUtils.normalizedRotation(page.rotation)

        do {
            try PDFKitEngine.shared.rotatePage(
                document,
                at: index,
                rotation: PDFUtils.normalizedRotation(rotation)
            )
            finishPageMutation(selecting: index)
            history.registerUndo(withTarget: self, actionName: actionName) { target in
                target.performRotation(
                    at: index,
                    rotation: previousRotation,
                    actionName: actionName
                )
            }
        } catch {
            showError("Failed to rotate page: \(error.localizedDescription)")
        }
    }

    private func performPageReorder(from sourceIndex: Int, to destinationIndex: Int, actionName: String) {
        guard let document = activeDocument else { return }
        let count = PDFKitEngine.shared.getPageCount(document)
        guard sourceIndex >= 0,
              sourceIndex < count,
              destinationIndex >= 0,
              destinationIndex < count,
              sourceIndex != destinationIndex else { return }

        do {
            try PDFKitEngine.shared.reorderPages(
                document,
                from: sourceIndex,
                to: destinationIndex
            )
            finishPageMutation(selecting: destinationIndex)
            history.registerUndo(withTarget: self, actionName: actionName) { target in
                target.performPageReorder(
                    from: destinationIndex,
                    to: sourceIndex,
                    actionName: actionName
                )
            }
        } catch {
            showError("Failed to move page: \(error.localizedDescription)")
        }
    }

    private func finishPageMutation(selecting index: Int) {
        markDocumentModified()
        refreshPages(selecting: index)
    }
}

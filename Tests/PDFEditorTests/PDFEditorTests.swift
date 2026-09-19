import Compression
import PDFKit
import XCTest
@testable import PDFEditorApp

@MainActor
final class PDFEditorTests: XCTestCase {
    func testDocumentStateClampsSelectionAfterPageChanges() {
        var state = DocumentState(
            pages: [
                PDFPageModel(index: 0),
                PDFPageModel(index: 1),
                PDFPageModel(index: 2)
            ],
            currentPageIndex: 2
        )

        state.replacePages(with: [PDFPageModel(index: 0)])

        XCTAssertEqual(state.currentPageIndex, 0)
        XCTAssertEqual(state.pages.count, 1)
    }

    func testRotationNormalization() {
        XCTAssertEqual(PDFUtils.normalizedRotation(450), 90)
        XCTAssertEqual(PDFUtils.normalizedRotation(-90), 270)
    }

    func testEnginePageLifecycleAndDirtyState() throws {
        let pdfDocument = PDFDocument()
        let firstPage = PDFPage()
        let secondPage = PDFPage()
        pdfDocument.insert(firstPage, at: 0)
        pdfDocument.insert(secondPage, at: 1)
        let wrapper = PDFDocumentWrapper(pdfDocument: pdfDocument)
        let engine = PDFKitEngine.shared

        XCTAssertEqual(engine.getPageCount(wrapper), 2)
        XCTAssertFalse(wrapper.isModified)

        try engine.rotatePage(wrapper, at: 0, rotation: 450)
        XCTAssertEqual(pdfDocument.page(at: 0)?.rotation, 90)
        XCTAssertTrue(wrapper.isModified)

        try engine.reorderPages(wrapper, from: 0, to: 1)
        XCTAssertTrue(pdfDocument.page(at: 1) === firstPage)

        try engine.duplicatePage(wrapper, at: 1)
        XCTAssertEqual(engine.getPageCount(wrapper), 3)
        XCTAssertFalse(pdfDocument.page(at: 2) === firstPage)

        try engine.removePage(wrapper, at: 2)
        XCTAssertEqual(engine.getPageCount(wrapper), 2)
    }

    func testPageMutationUndoRedoRoundTrip() {
        let pdfDocument = PDFDocument()
        pdfDocument.insert(PDFPage(), at: 0)
        let wrapper = PDFDocumentWrapper(pdfDocument: pdfDocument)
        let controller = DocumentController()
        controller.loadDocument(wrapper)

        controller.rotatePage(at: 0)
        XCTAssertEqual(pdfDocument.page(at: 0)?.rotation, 90)
        XCTAssertTrue(controller.history.canUndo)

        controller.history.undo()
        XCTAssertEqual(pdfDocument.page(at: 0)?.rotation, 0)
        XCTAssertTrue(controller.history.canRedo)

        controller.history.redo()
        XCTAssertEqual(pdfDocument.page(at: 0)?.rotation, 90)
    }

    func testExistingTextWritebackFailsExplicitlyWithoutMutation() {
        let pdfDocument = PDFDocument()
        pdfDocument.insert(PDFPage(), at: 0)
        let wrapper = PDFDocumentWrapper(pdfDocument: pdfDocument)

        do {
            try PDFContentEngine.shared.replaceText(
                document: wrapper,
                pageIndex: 0,
                oldText: "old",
                newText: "new"
            )
            XCTFail("Expected unsupportedContentWriteback")
        } catch let error as PDFContentError {
            guard case .textNotFound = error else {
                return XCTFail("Unexpected PDFContentError: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertFalse(wrapper.isModified)
        XCTAssertEqual(pdfDocument.pageCount, 1)
    }

    func testExistingLiteralTextWritebackChangesRealPDFBytes() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PDFEditor-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }

        try writeMinimalLiteralTextPDF(to: url, text: "Hello 100")

        guard let original = PDFDocument(url: url) else {
            return XCTFail("Fixture PDF should open in PDFKit")
        }
        XCTAssertTrue(original.page(at: 0)?.string?.contains("Hello 100") == true)

        let wrapper = PDFDocumentWrapper(url: url, pdfDocument: original)
        try PDFContentEngine.shared.replaceText(
            document: wrapper,
            pageIndex: 0,
            oldText: "100",
            newText: "120"
        )

        guard let reopened = PDFDocument(url: url) else {
            return XCTFail("Rewritten PDF should reopen in PDFKit")
        }
        let extracted = reopened.page(at: 0)?.string ?? ""
        XCTAssertTrue(extracted.contains("Hello 120"))
        XCTAssertFalse(extracted.contains("Hello 100"))

        let rawData = try Data(contentsOf: url)
        let raw = String(data: rawData, encoding: .isoLatin1) ?? ""
        // Incremental update intentionally preserves the previous PDF revision
        // while the newest xref points at the replacement stream object.
        XCTAssertTrue(raw.contains("(Hello 120) Tj"))
        XCTAssertGreaterThanOrEqual(
            raw.components(separatedBy: "startxref").count - 1,
            2
        )
    }

    func testExistingLiteralTextWritebackSupportsLengthChange() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PDFEditor-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }

        try writeMinimalLiteralTextPDF(to: url, text: "Hello 100")
        guard let pdf = PDFDocument(url: url) else {
            return XCTFail("Fixture PDF should open in PDFKit")
        }

        let wrapper = PDFDocumentWrapper(url: url, pdfDocument: pdf)
        try PDFContentEngine.shared.replaceText(
            document: wrapper,
            pageIndex: 0,
            oldText: "100",
            newText: "1200"
        )

        guard let reopened = PDFDocument(url: url) else {
            return XCTFail("Variable-length rewritten PDF should reopen")
        }
        let extracted = reopened.page(at: 0)?.string ?? ""
        XCTAssertTrue(extracted.contains("Hello 1200"))
        XCTAssertFalse(extracted.contains("Hello 100"))
    }

    func testCompressedLiteralTextWritebackSupportsLengthChange() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("compressed-literal-tj-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }

        try writeMinimalLiteralTextPDF(to: url, text: "Hello 100", compressed: true)
        guard let pdf = PDFDocument(url: url) else {
            return XCTFail("Compressed fixture PDF should open in PDFKit")
        }
        XCTAssertTrue(pdf.page(at: 0)?.string?.contains("Hello 100") == true)

        let wrapper = PDFDocumentWrapper(url: url, pdfDocument: pdf)
        try PDFContentEngine.shared.replaceText(
            document: wrapper,
            pageIndex: 0,
            oldText: "100",
            newText: "1200"
        )

        guard let reopened = PDFDocument(url: url) else {
            return XCTFail("Compressed rewritten PDF should reopen")
        }
        let extracted = reopened.page(at: 0)?.string ?? ""
        XCTAssertTrue(extracted.contains("Hello 1200"))
        XCTAssertFalse(extracted.contains("Hello 100"))
    }

    func testCompressedIncrementalWritebackCanBeAppliedTwice() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("compressed-literal-tj-twice-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }

        try writeMinimalLiteralTextPDF(to: url, text: "Hello 100", compressed: true)
        guard let original = PDFDocument(url: url) else {
            return XCTFail("Compressed fixture should open")
        }

        let wrapper = PDFDocumentWrapper(url: url, pdfDocument: original)
        try PDFContentEngine.shared.replaceText(
            document: wrapper,
            pageIndex: 0,
            oldText: "100",
            newText: "1200"
        )
        try PDFContentEngine.shared.replaceText(
            document: wrapper,
            pageIndex: 0,
            oldText: "1200",
            newText: "13000"
        )

        guard let reopened = PDFDocument(url: url) else {
            return XCTFail("Twice-updated PDF should reopen")
        }
        let extracted = reopened.page(at: 0)?.string ?? ""
        XCTAssertTrue(extracted.contains("Hello 13000"))
        XCTAssertFalse(extracted.contains("Hello 1200"))
        XCTAssertFalse(extracted.contains("Hello 100"))
    }

    func testTJArrayWritebackAcrossLiteralSegments() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tj-array-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }

        try writeTJArrayPDF(to: url, compressed: false)
        guard let pdf = PDFDocument(url: url) else {
            return XCTFail("TJ fixture should open")
        }

        XCTAssertTrue(pdf.page(at: 0)?.string?.contains("Hello 100") == true)

        let wrapper = PDFDocumentWrapper(url: url, pdfDocument: pdf)
        try PDFContentEngine.shared.replaceText(
            document: wrapper,
            pageIndex: 0,
            oldText: "100",
            newText: "1200"
        )

        guard let reopened = PDFDocument(url: url) else {
            return XCTFail("Rewritten TJ PDF should reopen")
        }
        let extracted = reopened.page(at: 0)?.string ?? ""
        XCTAssertTrue(extracted.contains("Hello 1200"))
        XCTAssertFalse(extracted.contains("Hello 100"))
    }

    func testCompressedTJArrayWritebackAcrossLiteralSegments() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tj-array-compressed-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }

        try writeTJArrayPDF(to: url, compressed: true)
        guard let pdf = PDFDocument(url: url) else {
            return XCTFail("Compressed TJ fixture should open")
        }

        XCTAssertTrue(pdf.page(at: 0)?.string?.contains("Hello 100") == true)

        let wrapper = PDFDocumentWrapper(url: url, pdfDocument: pdf)
        try PDFContentEngine.shared.replaceText(
            document: wrapper,
            pageIndex: 0,
            oldText: "Hello 100",
            newText: "Hi 1200"
        )

        guard let reopened = PDFDocument(url: url) else {
            return XCTFail("Compressed rewritten TJ PDF should reopen")
        }
        let extracted = reopened.page(at: 0)?.string ?? ""
        XCTAssertTrue(extracted.contains("Hi 1200"))
        XCTAssertFalse(extracted.contains("Hello 100"))
    }

    func testHexTjWritebackSupportsLengthChange() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hex-tj-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }

        try writeHexTjPDF(to: url, compressed: false)
        guard let pdf = PDFDocument(url: url) else {
            return XCTFail("Hex Tj fixture should open")
        }
        XCTAssertTrue(pdf.page(at: 0)?.string?.contains("Hello 100") == true)

        let wrapper = PDFDocumentWrapper(url: url, pdfDocument: pdf)
        try PDFContentEngine.shared.replaceText(
            document: wrapper,
            pageIndex: 0,
            oldText: "100",
            newText: "1200"
        )

        guard let reopened = PDFDocument(url: url) else {
            return XCTFail("Rewritten hex Tj PDF should reopen")
        }
        let extracted = reopened.page(at: 0)?.string ?? ""
        XCTAssertTrue(extracted.contains("Hello 1200"))
        XCTAssertFalse(extracted.contains("Hello 100"))
    }

    func testCompressedHexTjWritebackSupportsLengthChange() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hex-tj-compressed-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }

        try writeHexTjPDF(to: url, compressed: true)
        guard let pdf = PDFDocument(url: url) else {
            return XCTFail("Compressed hex Tj fixture should open")
        }
        XCTAssertTrue(pdf.page(at: 0)?.string?.contains("Hello 100") == true)

        let wrapper = PDFDocumentWrapper(url: url, pdfDocument: pdf)
        try PDFContentEngine.shared.replaceText(
            document: wrapper,
            pageIndex: 0,
            oldText: "Hello 100",
            newText: "Hi 1200"
        )

        guard let reopened = PDFDocument(url: url) else {
            return XCTFail("Compressed rewritten hex Tj PDF should reopen")
        }
        let extracted = reopened.page(at: 0)?.string ?? ""
        XCTAssertTrue(extracted.contains("Hi 1200"))
        XCTAssertFalse(extracted.contains("Hello 100"))
    }

    func testMixedLiteralAndHexTJArrayWriteback() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tj-mixed-hex-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }

        try writeMixedHexTJArrayPDF(to: url, compressed: false)
        guard let pdf = PDFDocument(url: url) else {
            return XCTFail("Mixed TJ fixture should open")
        }
        XCTAssertTrue(pdf.page(at: 0)?.string?.contains("Hello 100") == true)

        let wrapper = PDFDocumentWrapper(url: url, pdfDocument: pdf)
        try PDFContentEngine.shared.replaceText(
            document: wrapper,
            pageIndex: 0,
            oldText: "Hello 100",
            newText: "Hi 1200"
        )

        guard let reopened = PDFDocument(url: url) else {
            return XCTFail("Mixed TJ rewritten PDF should reopen")
        }
        let extracted = reopened.page(at: 0)?.string ?? ""
        XCTAssertTrue(extracted.contains("Hi 1200"))
        XCTAssertFalse(extracted.contains("Hello 100"))
    }

    func testCompressedMixedLiteralAndHexTJArrayWriteback() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tj-mixed-hex-compressed-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }

        try writeMixedHexTJArrayPDF(to: url, compressed: true)
        guard let pdf = PDFDocument(url: url) else {
            return XCTFail("Compressed mixed TJ fixture should open")
        }
        XCTAssertTrue(pdf.page(at: 0)?.string?.contains("Hello 100") == true)

        let wrapper = PDFDocumentWrapper(url: url, pdfDocument: pdf)
        try PDFContentEngine.shared.replaceText(
            document: wrapper,
            pageIndex: 0,
            oldText: "100",
            newText: "1200"
        )

        guard let reopened = PDFDocument(url: url) else {
            return XCTFail("Compressed mixed TJ rewritten PDF should reopen")
        }
        let extracted = reopened.page(at: 0)?.string ?? ""
        XCTAssertTrue(extracted.contains("Hello 1200"))
        XCTAssertFalse(extracted.contains("Hello 100"))
    }

    func testType0IdentityHToUnicodeCIDWriteback() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("type0-tounicode-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }

        try writeType0ToUnicodePDF(to: url, compressed: true)

        guard let pdf = PDFDocument(url: url) else {
            return XCTFail("Type0 ToUnicode fixture should open")
        }
        let originalText = pdf.page(at: 0)?.string ?? ""
        XCTAssertTrue(originalText.contains("你好100"))

        let wrapper = PDFDocumentWrapper(url: url, pdfDocument: pdf)
        try PDFContentEngine.shared.replaceText(
            document: wrapper,
            pageIndex: 0,
            oldText: "你好100",
            newText: "您好1200"
        )

        guard let reopened = PDFDocument(url: url) else {
            return XCTFail("Rewritten Type0 PDF should reopen")
        }
        let extracted = reopened.page(at: 0)?.string ?? ""
        XCTAssertTrue(extracted.contains("您好1200"))
        XCTAssertFalse(extracted.contains("你好100"))
    }

    func testType0IdentityHToUnicodeCIDTJArrayWriteback() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("type0-tounicode-tj-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }

        try writeType0ToUnicodePDF(
            to: url,
            compressed: true,
            useTJArray: true
        )

        guard let pdf = PDFDocument(url: url) else {
            return XCTFail("Type0 TJ fixture should open")
        }
        XCTAssertTrue(pdf.page(at: 0)?.string?.contains("你好100") == true)

        let wrapper = PDFDocumentWrapper(url: url, pdfDocument: pdf)
        try PDFContentEngine.shared.replaceText(
            document: wrapper,
            pageIndex: 0,
            oldText: "你好100",
            newText: "您好1200"
        )

        guard let reopened = PDFDocument(url: url) else {
            return XCTFail("Rewritten Type0 TJ PDF should reopen")
        }
        let extracted = reopened.page(at: 0)?.string ?? ""
        XCTAssertTrue(extracted.contains("您好1200"))
        XCTAssertFalse(extracted.contains("你好100"))
    }

    func testType0ToUnicodeBFRangeArrayWriteback() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("type0-bfrange-array-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }

        try writeType0ToUnicodePDF(
            to: url,
            compressed: true,
            useBFRangeArray: true
        )

        guard let pdf = PDFDocument(url: url) else {
            return XCTFail("bfrange-array fixture should open")
        }
        XCTAssertTrue(pdf.page(at: 0)?.string?.contains("你好100") == true)

        let wrapper = PDFDocumentWrapper(url: url, pdfDocument: pdf)
        try PDFContentEngine.shared.replaceText(
            document: wrapper,
            pageIndex: 0,
            oldText: "你好100",
            newText: "您好1200"
        )

        guard let reopened = PDFDocument(url: url) else {
            return XCTFail("Rewritten bfrange-array PDF should reopen")
        }
        let extracted = reopened.page(at: 0)?.string ?? ""
        let rewrittenObjects = try MinimalPDFTextRewriter.textObjects(in: url)
            .map(\.text)
        XCTAssertTrue(
            extracted.contains("您好1200"),
            "PDFKit extracted: \(extracted); writer objects: \(rewrittenObjects)"
        )
        XCTAssertFalse(extracted.contains("你好100"))
    }

    func testIndirectResourcesAndFontDictionaryResolveCMap() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("indirect-resources-font-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }

        try writeType0ToUnicodePDF(
            to: url,
            compressed: true,
            indirectResourcesAndFont: true
        )

        guard let pdf = PDFDocument(url: url) else {
            return XCTFail("Indirect resource fixture should open")
        }
        XCTAssertTrue((pdf.page(at: 0)?.string ?? "").contains("你好100"))

        let objects = try MinimalPDFTextRewriter.textObjects(in: url)
        guard let target = objects.first(where: { $0.text == "你好100" }) else {
            return XCTFail("Indirect /Resources -> /Font map should resolve")
        }
        XCTAssertEqual(target.fontResourceName, "F1")

        try MinimalPDFTextRewriter.replaceText(
            in: url,
            target: target.id,
            oldText: "你好100",
            newText: "您好1200"
        )

        guard let reopened = PDFDocument(url: url) else {
            return XCTFail("Indirect-resource rewritten PDF should reopen")
        }
        let extracted = reopened.page(at: 0)?.string ?? ""
        XCTAssertTrue(extracted.contains("您好1200"))
        XCTAssertFalse(extracted.contains("你好100"))
    }

    func testMixedSimpleAndType0FontsUseActiveTfCMap() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mixed-font-cmap-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }

        try writeMixedSimpleAndType0PDF(to: url)

        guard let pdf = PDFDocument(url: url) else {
            return XCTFail("Mixed-font fixture should open")
        }
        let original = pdf.page(at: 0)?.string ?? ""
        XCTAssertTrue(original.contains("Hello"))
        XCTAssertTrue(original.contains("你好100"))

        let wrapper = PDFDocumentWrapper(url: url, pdfDocument: pdf)
        try PDFContentEngine.shared.replaceText(
            document: wrapper,
            pageIndex: 0,
            oldText: "你好100",
            newText: "您好1200"
        )

        guard let reopened = PDFDocument(url: url) else {
            return XCTFail("Mixed-font rewritten PDF should reopen")
        }
        let extracted = reopened.page(at: 0)?.string ?? ""
        XCTAssertTrue(extracted.contains("Hello"))
        XCTAssertTrue(extracted.contains("您好1200"))
        XCTAssertFalse(extracted.contains("你好100"))
    }

    func testMixedLengthToUnicodeSourceCodesWriteback() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mixed-length-cmap-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }

        try writeMixedLengthToUnicodePDF(to: url)

        guard let pdf = PDFDocument(url: url) else {
            return XCTFail("Mixed-length CMap fixture should open")
        }
        XCTAssertTrue((pdf.page(at: 0)?.string ?? "").contains("你好100"))

        let objects = try MinimalPDFTextRewriter.textObjects(in: url)
        guard let target = objects.first(where: { $0.text == "你好100" }) else {
            return XCTFail("Mixed-length source codes should decode")
        }

        try MinimalPDFTextRewriter.replaceText(
            in: url,
            target: target.id,
            oldText: "你好100",
            newText: "您好1200"
        )

        guard let reopened = PDFDocument(url: url) else {
            return XCTFail("Mixed-length rewritten PDF should reopen")
        }
        let extracted = reopened.page(at: 0)?.string ?? ""
        XCTAssertTrue(extracted.contains("您好1200"))
        XCTAssertFalse(extracted.contains("你好100"))
    }

    func testInheritedPageTreeResourcesUseBranchSpecificCMap() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("inherited-page-resources-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }

        try writeTwoPageInheritedResourceType0PDF(to: url)

        guard let pdf = PDFDocument(url: url) else {
            return XCTFail("Inherited-resource fixture should open")
        }
        XCTAssertEqual(pdf.pageCount, 2)
        XCTAssertTrue((pdf.page(at: 0)?.string ?? "").contains("你100"))
        XCTAssertTrue((pdf.page(at: 1)?.string ?? "").contains("您100"))

        let objects = try MinimalPDFTextRewriter.textObjects(in: url)
        XCTAssertNotNil(objects.first { $0.text == "你100" })
        guard let target = objects.first(where: { $0.text == "您100" }) else {
            return XCTFail("Inherited second-page CMap should resolve")
        }

        try MinimalPDFTextRewriter.replaceText(
            in: url,
            target: target.id,
            oldText: "您100",
            newText: "好1200"
        )

        guard let reopened = PDFDocument(url: url) else {
            return XCTFail("Inherited-resource rewritten PDF should reopen")
        }
        XCTAssertTrue((reopened.page(at: 0)?.string ?? "").contains("你100"))
        XCTAssertTrue((reopened.page(at: 1)?.string ?? "").contains("好1200"))
        XCTAssertFalse((reopened.page(at: 1)?.string ?? "").contains("您100"))
    }

    func testSameF1OnDifferentPagesUsesPageSpecificCMap() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("page-specific-f1-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }

        try writeTwoPageSameResourceDifferentType0PDF(to: url)

        guard let pdf = PDFDocument(url: url) else {
            return XCTFail("Two-page Type0 fixture should open")
        }
        XCTAssertEqual(pdf.pageCount, 2)
        XCTAssertTrue((pdf.page(at: 0)?.string ?? "").contains("你100"))
        XCTAssertTrue((pdf.page(at: 1)?.string ?? "").contains("您100"))

        let objects = try MinimalPDFTextRewriter.textObjects(in: url)
        let first = objects.first { $0.text == "你100" }
        let second = objects.first { $0.text == "您100" }

        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        XCTAssertEqual(first?.fontResourceName, "F1")
        XCTAssertEqual(second?.fontResourceName, "F1")
        XCTAssertNotEqual(first?.id.streamObjectNumber, second?.id.streamObjectNumber)

        guard let second else {
            return XCTFail("Second page text object should be discoverable")
        }

        try MinimalPDFTextRewriter.replaceText(
            in: url,
            target: second.id,
            oldText: "您100",
            newText: "好1200"
        )

        guard let reopened = PDFDocument(url: url) else {
            return XCTFail("Page-specific rewritten PDF should reopen")
        }
        XCTAssertTrue((reopened.page(at: 0)?.string ?? "").contains("你100"))
        XCTAssertTrue((reopened.page(at: 1)?.string ?? "").contains("好1200"))
        XCTAssertFalse((reopened.page(at: 1)?.string ?? "").contains("您100"))
    }

    func testTargetedTextObjectReplacesOnlySelectedDuplicate() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("targeted-duplicate-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }

        let streamText = """
        BT
        /F1 12 Tf
        72 740 Td
        (100) Tj
        0 -20 Td
        (100) Tj
        ET
        """
        try writeCustomContentPDF(
            to: url,
            streamText: streamText,
            compressed: true
        )

        guard let original = PDFDocument(url: url) else {
            return XCTFail("Duplicate-text fixture should open")
        }
        XCTAssertTrue((original.page(at: 0)?.string ?? "").contains("100"))

        let beforeObjects = try MinimalPDFTextRewriter.textObjects(in: url)
            .filter { $0.text == "100" }
            .sorted {
                $0.id.operatorStartOffset < $1.id.operatorStartOffset
            }

        XCTAssertEqual(beforeObjects.count, 2)
        XCTAssertNotEqual(beforeObjects[0].id, beforeObjects[1].id)

        try MinimalPDFTextRewriter.replaceText(
            in: url,
            target: beforeObjects[1].id,
            oldText: "100",
            newText: "1200"
        )

        guard let reopened = PDFDocument(url: url) else {
            return XCTFail("Targeted rewritten PDF should reopen")
        }
        let extracted = reopened.page(at: 0)?.string ?? ""
        XCTAssertTrue(extracted.contains("100"))
        XCTAssertTrue(extracted.contains("1200"))

        // Enumeration must expose only the latest incremental stream revision,
        // not both the old and new revisions of the same object.
        let afterObjects = try MinimalPDFTextRewriter.textObjects(in: url)
        XCTAssertEqual(afterObjects.filter { $0.text == "100" }.count, 1)
        XCTAssertEqual(afterObjects.filter { $0.text == "1200" }.count, 1)
        XCTAssertEqual(afterObjects.filter {
            $0.text == "100" || $0.text == "1200"
        }.count, 2)
    }

    func testIndirectLengthCompressedWriteback() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("indirect-length-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }

        let streamText = "BT\n/F1 12 Tf\n72 720 Td\n(Hello 100) Tj\nET\n"
        try writeCustomContentPDF(
            to: url,
            streamText: streamText,
            compressed: true,
            indirectLength: true
        )

        guard let pdf = PDFDocument(url: url) else {
            return XCTFail("Indirect-Length fixture should open")
        }
        XCTAssertTrue(pdf.page(at: 0)?.string?.contains("Hello 100") == true)

        let wrapper = PDFDocumentWrapper(url: url, pdfDocument: pdf)
        try PDFContentEngine.shared.replaceText(
            document: wrapper,
            pageIndex: 0,
            oldText: "100",
            newText: "1200"
        )

        guard let reopened = PDFDocument(url: url) else {
            return XCTFail("Rewritten indirect-Length PDF should reopen")
        }
        let extracted = reopened.page(at: 0)?.string ?? ""
        XCTAssertTrue(extracted.contains("Hello 1200"))
        XCTAssertFalse(extracted.contains("Hello 100"))
    }

    func testAmbiguousWritebackFailsWithoutCorruptingPDF() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PDFEditor-ambiguous-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }

        try writeMinimalLiteralTextPDF(to: url, text: "100 and 100")
        let before = try Data(contentsOf: url)
        guard let pdf = PDFDocument(url: url) else {
            return XCTFail("Fixture PDF should open")
        }

        let wrapper = PDFDocumentWrapper(url: url, pdfDocument: pdf)
        XCTAssertThrowsError(
            try PDFContentEngine.shared.replaceText(
                document: wrapper,
                pageIndex: 0,
                oldText: "100",
                newText: "1200"
            )
        )

        let after = try Data(contentsOf: url)
        XCTAssertEqual(before, after)
        guard let reopened = PDFDocument(url: url) else {
            return XCTFail("Failed writeback must leave a valid PDF")
        }
        XCTAssertTrue(reopened.page(at: 0)?.string?.contains("100 and 100") == true)
    }

    private func writeMixedLengthToUnicodePDF(to url: URL) throws {
        // 1-byte source codes are in 0x20...0x7F; 2-byte source codes are in
        // 0x81xx, so the codespaces are unambiguous.
        let content = "BT\n/F1 16 Tf\n72 720 Td\n<418102313030> Tj\nET\n"
        guard let contentPlain = content.data(using: .ascii) else {
            throw NSError(domain: "PDFEditorTests", code: 50)
        }
        let contentData = try zlibEncodeForFixture(contentPlain)

        let cmap = """
        /CIDInit /ProcSet findresource begin
        12 dict begin
        begincmap
        /CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def
        /CMapName /MixedLength-UCS def
        /CMapType 2 def
        2 begincodespacerange
        <20> <7F>
        <8100> <81FF>
        endcodespacerange
        6 beginbfchar
        <41> <4F60>
        <42> <60A8>
        <8102> <597D>
        <30> <0030>
        <31> <0031>
        <32> <0032>
        endbfchar
        endcmap
        CMapName currentdict /CMap defineresource pop
        end
        end
        """
        guard let cmapPlain = cmap.data(using: .ascii) else {
            throw NSError(domain: "PDFEditorTests", code: 51)
        }
        let cmapData = try zlibEncodeForFixture(cmapPlain)

        var pdf = Data("%PDF-1.4\n".utf8)
        var offsets = [Int](repeating: -1, count: 9)

        func appendObject(_ number: Int, header: String, stream: Data? = nil) {
            offsets[number] = pdf.count
            pdf.append(contentsOf: "\(number) 0 obj\n".utf8)
            pdf.append(contentsOf: header.utf8)
            if let stream {
                pdf.append(contentsOf: "\nstream\n".utf8)
                pdf.append(stream)
                pdf.append(contentsOf: "\nendstream".utf8)
            }
            pdf.append(contentsOf: "\nendobj\n".utf8)
        }

        appendObject(1, header: "<< /Type /Catalog /Pages 2 0 R >>")
        appendObject(2, header: "<< /Type /Pages /Kids [3 0 R] /Count 1 >>")
        appendObject(
            3,
            header: "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 4 0 R >> >> /Contents 8 0 R >>"
        )
        appendObject(
            4,
            header: "<< /Type /Font /Subtype /Type0 /BaseFont /MixedLengthCID /Encoding /Identity-H /DescendantFonts [5 0 R] /ToUnicode 7 0 R >>"
        )
        appendObject(
            5,
            header: "<< /Type /Font /Subtype /CIDFontType2 /BaseFont /Helvetica /CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >> /FontDescriptor 6 0 R /DW 1000 /CIDToGIDMap /Identity >>"
        )
        appendObject(
            6,
            header: "<< /Type /FontDescriptor /FontName /Helvetica /Flags 32 /FontBBox [0 -200 1000 900] /ItalicAngle 0 /Ascent 800 /Descent -200 /CapHeight 700 /StemV 80 >>"
        )
        appendObject(
            7,
            header: "<< /Length \(cmapData.count) /Filter /FlateDecode >>",
            stream: cmapData
        )
        appendObject(
            8,
            header: "<< /Length \(contentData.count) /Filter /FlateDecode >>",
            stream: contentData
        )

        let objectCount = 8
        let xrefOffset = pdf.count
        pdf.append(contentsOf: "xref\n0 \(objectCount + 1)\n".utf8)
        pdf.append(contentsOf: "0000000000 65535 f \n".utf8)
        for number in 1...objectCount {
            pdf.append(
                contentsOf: String(
                    format: "%010d 00000 n \n",
                    offsets[number]
                ).utf8
            )
        }
        pdf.append(
            contentsOf: "trailer\n<< /Size \(objectCount + 1) /Root 1 0 R >>\n".utf8
        )
        pdf.append(contentsOf: "startxref\n\(xrefOffset)\n%%EOF\n".utf8)

        try pdf.write(to: url, options: .atomic)
    }

    private func writeTwoPageInheritedResourceType0PDF(
        to url: URL
    ) throws {
        let content1 = "BT\n/F1 16 Tf\n72 720 Td\n<0001001100100010> Tj\nET\n"
        let content2 = "BT\n/F1 16 Tf\n72 720 Td\n<0001001100100010> Tj\nET\n"
        guard let content1Plain = content1.data(using: .ascii),
              let content2Plain = content2.data(using: .ascii) else {
            throw NSError(domain: "PDFEditorTests", code: 40)
        }

        let content1Data = try zlibEncodeForFixture(content1Plain)
        let content2Data = try zlibEncodeForFixture(content2Plain)

        let cmapA = """
        /CIDInit /ProcSet findresource begin
        12 dict begin
        begincmap
        /CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def
        /CMapName /InheritedOne-UCS def
        /CMapType 2 def
        1 begincodespacerange
        <0000> <FFFF>
        endcodespacerange
        2 beginbfchar
        <0001> <4F60>
        <0002> <597D>
        endbfchar
        1 beginbfrange
        <0010> <0012> <0030>
        endbfrange
        endcmap
        CMapName currentdict /CMap defineresource pop
        end
        end
        """
        let cmapB = """
        /CIDInit /ProcSet findresource begin
        12 dict begin
        begincmap
        /CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def
        /CMapName /InheritedTwo-UCS def
        /CMapType 2 def
        1 begincodespacerange
        <0000> <FFFF>
        endcodespacerange
        2 beginbfchar
        <0001> <60A8>
        <0002> <597D>
        endbfchar
        1 beginbfrange
        <0010> <0012> <0030>
        endbfrange
        endcmap
        CMapName currentdict /CMap defineresource pop
        end
        end
        """

        guard let cmapAPlain = cmapA.data(using: .ascii),
              let cmapBPlain = cmapB.data(using: .ascii) else {
            throw NSError(domain: "PDFEditorTests", code: 41)
        }
        let cmapAData = try zlibEncodeForFixture(cmapAPlain)
        let cmapBData = try zlibEncodeForFixture(cmapBPlain)

        var pdf = Data("%PDF-1.4\n".utf8)
        var offsets = [Int](repeating: -1, count: 15)

        func appendObject(_ number: Int, header: String, stream: Data? = nil) {
            offsets[number] = pdf.count
            pdf.append(contentsOf: "\(number) 0 obj\n".utf8)
            pdf.append(contentsOf: header.utf8)
            if let stream {
                pdf.append(contentsOf: "\nstream\n".utf8)
                pdf.append(stream)
                pdf.append(contentsOf: "\nendstream".utf8)
            }
            pdf.append(contentsOf: "\nendobj\n".utf8)
        }

        appendObject(1, header: "<< /Type /Catalog /Pages 2 0 R >>")
        appendObject(
            2,
            header: "<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>"
        )
        appendObject(
            3,
            header: "<< /Type /Pages /Parent 2 0 R /Kids [5 0 R] /Count 1 /Resources << /Font << /F1 7 0 R >> >> >>"
        )
        appendObject(
            4,
            header: "<< /Type /Pages /Parent 2 0 R /Kids [6 0 R] /Count 1 /Resources << /Font << /F1 8 0 R >> >> >>"
        )
        appendObject(
            5,
            header: "<< /Type /Page /Parent 3 0 R /MediaBox [0 0 612 792] /Contents 13 0 R >>"
        )
        appendObject(
            6,
            header: "<< /Type /Page /Parent 4 0 R /MediaBox [0 0 612 792] /Contents 14 0 R >>"
        )
        appendObject(
            7,
            header: "<< /Type /Font /Subtype /Type0 /BaseFont /InheritedOne /Encoding /Identity-H /DescendantFonts [9 0 R] /ToUnicode 11 0 R >>"
        )
        appendObject(
            8,
            header: "<< /Type /Font /Subtype /Type0 /BaseFont /InheritedTwo /Encoding /Identity-H /DescendantFonts [9 0 R] /ToUnicode 12 0 R >>"
        )
        appendObject(
            9,
            header: "<< /Type /Font /Subtype /CIDFontType2 /BaseFont /Helvetica /CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >> /FontDescriptor 10 0 R /DW 1000 /CIDToGIDMap /Identity >>"
        )
        appendObject(
            10,
            header: "<< /Type /FontDescriptor /FontName /Helvetica /Flags 32 /FontBBox [0 -200 1000 900] /ItalicAngle 0 /Ascent 800 /Descent -200 /CapHeight 700 /StemV 80 >>"
        )
        appendObject(
            11,
            header: "<< /Length \(cmapAData.count) /Filter /FlateDecode >>",
            stream: cmapAData
        )
        appendObject(
            12,
            header: "<< /Length \(cmapBData.count) /Filter /FlateDecode >>",
            stream: cmapBData
        )
        appendObject(
            13,
            header: "<< /Length \(content1Data.count) /Filter /FlateDecode >>",
            stream: content1Data
        )
        appendObject(
            14,
            header: "<< /Length \(content2Data.count) /Filter /FlateDecode >>",
            stream: content2Data
        )

        let objectCount = 14
        let xrefOffset = pdf.count
        pdf.append(contentsOf: "xref\n0 \(objectCount + 1)\n".utf8)
        pdf.append(contentsOf: "0000000000 65535 f \n".utf8)
        for number in 1...objectCount {
            pdf.append(
                contentsOf: String(
                    format: "%010d 00000 n \n",
                    offsets[number]
                ).utf8
            )
        }
        pdf.append(
            contentsOf: "trailer\n<< /Size \(objectCount + 1) /Root 1 0 R >>\n".utf8
        )
        pdf.append(contentsOf: "startxref\n\(xrefOffset)\n%%EOF\n".utf8)

        try pdf.write(to: url, options: .atomic)
    }

    private func writeTwoPageSameResourceDifferentType0PDF(
        to url: URL
    ) throws {
        let content1 = "BT\n/F1 16 Tf\n72 720 Td\n<0001001100100010> Tj\nET\n"
        let content2 = "BT\n/F1 16 Tf\n72 720 Td\n<0001001100100010> Tj\nET\n"

        guard let content1Plain = content1.data(using: .ascii),
              let content2Plain = content2.data(using: .ascii) else {
            throw NSError(domain: "PDFEditorTests", code: 30)
        }

        let content1Data = try zlibEncodeForFixture(content1Plain)
        let content2Data = try zlibEncodeForFixture(content2Plain)

        let cmapA = """
        /CIDInit /ProcSet findresource begin
        12 dict begin
        begincmap
        /CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def
        /CMapName /PageOne-UCS def
        /CMapType 2 def
        1 begincodespacerange
        <0000> <FFFF>
        endcodespacerange
        2 beginbfchar
        <0001> <4F60>
        <0002> <597D>
        endbfchar
        1 beginbfrange
        <0010> <0012> <0030>
        endbfrange
        endcmap
        CMapName currentdict /CMap defineresource pop
        end
        end
        """

        let cmapB = """
        /CIDInit /ProcSet findresource begin
        12 dict begin
        begincmap
        /CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def
        /CMapName /PageTwo-UCS def
        /CMapType 2 def
        1 begincodespacerange
        <0000> <FFFF>
        endcodespacerange
        2 beginbfchar
        <0001> <60A8>
        <0002> <597D>
        endbfchar
        1 beginbfrange
        <0010> <0012> <0030>
        endbfrange
        endcmap
        CMapName currentdict /CMap defineresource pop
        end
        end
        """

        guard let cmapAPlain = cmapA.data(using: .ascii),
              let cmapBPlain = cmapB.data(using: .ascii) else {
            throw NSError(domain: "PDFEditorTests", code: 31)
        }

        let cmapAData = try zlibEncodeForFixture(cmapAPlain)
        let cmapBData = try zlibEncodeForFixture(cmapBPlain)

        var pdf = Data("%PDF-1.4\n".utf8)
        var offsets = [Int](repeating: -1, count: 13)

        func appendObject(_ number: Int, header: String, stream: Data? = nil) {
            offsets[number] = pdf.count
            pdf.append(contentsOf: "\(number) 0 obj\n".utf8)
            pdf.append(contentsOf: header.utf8)
            if let stream {
                pdf.append(contentsOf: "\nstream\n".utf8)
                pdf.append(stream)
                pdf.append(contentsOf: "\nendstream".utf8)
            }
            pdf.append(contentsOf: "\nendobj\n".utf8)
        }

        appendObject(1, header: "<< /Type /Catalog /Pages 2 0 R >>")
        appendObject(
            2,
            header: "<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>"
        )
        appendObject(
            3,
            header: "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 5 0 R >> >> /Contents 11 0 R >>"
        )
        appendObject(
            4,
            header: "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 6 0 R >> >> /Contents 12 0 R >>"
        )
        appendObject(
            5,
            header: "<< /Type /Font /Subtype /Type0 /BaseFont /PageOneCID /Encoding /Identity-H /DescendantFonts [7 0 R] /ToUnicode 9 0 R >>"
        )
        appendObject(
            6,
            header: "<< /Type /Font /Subtype /Type0 /BaseFont /PageTwoCID /Encoding /Identity-H /DescendantFonts [7 0 R] /ToUnicode 10 0 R >>"
        )
        appendObject(
            7,
            header: "<< /Type /Font /Subtype /CIDFontType2 /BaseFont /Helvetica /CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >> /FontDescriptor 8 0 R /DW 1000 /CIDToGIDMap /Identity >>"
        )
        appendObject(
            8,
            header: "<< /Type /FontDescriptor /FontName /Helvetica /Flags 32 /FontBBox [0 -200 1000 900] /ItalicAngle 0 /Ascent 800 /Descent -200 /CapHeight 700 /StemV 80 >>"
        )
        appendObject(
            9,
            header: "<< /Length \(cmapAData.count) /Filter /FlateDecode >>",
            stream: cmapAData
        )
        appendObject(
            10,
            header: "<< /Length \(cmapBData.count) /Filter /FlateDecode >>",
            stream: cmapBData
        )
        appendObject(
            11,
            header: "<< /Length \(content1Data.count) /Filter /FlateDecode >>",
            stream: content1Data
        )
        appendObject(
            12,
            header: "<< /Length \(content2Data.count) /Filter /FlateDecode >>",
            stream: content2Data
        )

        let objectCount = 12
        let xrefOffset = pdf.count
        pdf.append(contentsOf: "xref\n0 \(objectCount + 1)\n".utf8)
        pdf.append(contentsOf: "0000000000 65535 f \n".utf8)
        for number in 1...objectCount {
            pdf.append(
                contentsOf: String(
                    format: "%010d 00000 n \n",
                    offsets[number]
                ).utf8
            )
        }
        pdf.append(
            contentsOf: "trailer\n<< /Size \(objectCount + 1) /Root 1 0 R >>\n".utf8
        )
        pdf.append(contentsOf: "startxref\n\(xrefOffset)\n%%EOF\n".utf8)

        try pdf.write(to: url, options: .atomic)
    }

    private func writeMixedSimpleAndType0PDF(to url: URL) throws {
        let content = """
        BT
        /F1 12 Tf
        72 740 Td
        <48656C6C6F> Tj
        ET
        BT
        /F2 16 Tf
        72 720 Td
        <00010002001100100010> Tj
        ET
        """
        guard let contentPlain = content.data(using: .ascii) else {
            throw NSError(domain: "PDFEditorTests", code: 20)
        }
        let contentData = try zlibEncodeForFixture(contentPlain)

        let cmap = """
        /CIDInit /ProcSet findresource begin
        12 dict begin
        begincmap
        /CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def
        /CMapName /Adobe-Identity-UCS def
        /CMapType 2 def
        1 begincodespacerange
        <0000> <FFFF>
        endcodespacerange
        3 beginbfchar
        <0001> <4F60>
        <0002> <597D>
        <0003> <60A8>
        endbfchar
        1 beginbfrange
        <0010> <0012> <0030>
        endbfrange
        endcmap
        CMapName currentdict /CMap defineresource pop
        end
        end
        """
        guard let cmapPlain = cmap.data(using: .ascii) else {
            throw NSError(domain: "PDFEditorTests", code: 21)
        }
        let cmapData = try zlibEncodeForFixture(cmapPlain)

        var pdf = Data("%PDF-1.4\n".utf8)
        var offsets = [Int](repeating: -1, count: 10)

        func appendObject(_ number: Int, header: String, stream: Data? = nil) {
            offsets[number] = pdf.count
            pdf.append(contentsOf: "\(number) 0 obj\n".utf8)
            pdf.append(contentsOf: header.utf8)
            if let stream {
                pdf.append(contentsOf: "\nstream\n".utf8)
                pdf.append(stream)
                pdf.append(contentsOf: "\nendstream".utf8)
            }
            pdf.append(contentsOf: "\nendobj\n".utf8)
        }

        appendObject(1, header: "<< /Type /Catalog /Pages 2 0 R >>")
        appendObject(2, header: "<< /Type /Pages /Kids [3 0 R] /Count 1 >>")
        appendObject(
            3,
            header: "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 4 0 R /F2 5 0 R >> >> /Contents 9 0 R >>"
        )
        appendObject(4, header: "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
        appendObject(
            5,
            header: "<< /Type /Font /Subtype /Type0 /BaseFont /TestCID /Encoding /Identity-H /DescendantFonts [6 0 R] /ToUnicode 8 0 R >>"
        )
        appendObject(
            6,
            header: "<< /Type /Font /Subtype /CIDFontType2 /BaseFont /Helvetica /CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >> /FontDescriptor 7 0 R /DW 1000 /CIDToGIDMap /Identity >>"
        )
        appendObject(
            7,
            header: "<< /Type /FontDescriptor /FontName /Helvetica /Flags 32 /FontBBox [0 -200 1000 900] /ItalicAngle 0 /Ascent 800 /Descent -200 /CapHeight 700 /StemV 80 >>"
        )
        appendObject(
            8,
            header: "<< /Length \(cmapData.count) /Filter /FlateDecode >>",
            stream: cmapData
        )
        appendObject(
            9,
            header: "<< /Length \(contentData.count) /Filter /FlateDecode >>",
            stream: contentData
        )

        let objectCount = 9
        let xrefOffset = pdf.count
        pdf.append(contentsOf: "xref\n0 \(objectCount + 1)\n".utf8)
        pdf.append(contentsOf: "0000000000 65535 f \n".utf8)
        for number in 1...objectCount {
            pdf.append(contentsOf: String(format: "%010d 00000 n \n", offsets[number]).utf8)
        }
        pdf.append(contentsOf: "trailer\n<< /Size \(objectCount + 1) /Root 1 0 R >>\n".utf8)
        pdf.append(contentsOf: "startxref\n\(xrefOffset)\n%%EOF\n".utf8)

        try pdf.write(to: url, options: .atomic)
    }

    private func writeType0ToUnicodePDF(
        to url: URL,
        compressed: Bool,
        useTJArray: Bool = false,
        useBFRangeArray: Bool = false,
        indirectResourcesAndFont: Bool = false
    ) throws {
        let textOperator = useTJArray
            ? "[<0001> -25 <0002> 10 <001100100010>] TJ"
            : "<00010002001100100010> Tj"
        let content = "BT\n/F1 16 Tf\n72 720 Td\n\(textOperator)\nET\n"
        guard let contentPlain = content.data(using: .ascii) else {
            throw NSError(domain: "PDFEditorTests", code: 10)
        }
        let contentData = compressed ? try zlibEncodeForFixture(contentPlain) : contentPlain

        let numericRange = useBFRangeArray
            ? """
              1 beginbfrange
              <0010> <0012> [<0030> <0031> <0032>]
              endbfrange
              """
            : """
              1 beginbfrange
              <0010> <0012> <0030>
              endbfrange
              """

        let cmap = """
        /CIDInit /ProcSet findresource begin
        12 dict begin
        begincmap
        /CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def
        /CMapName /Adobe-Identity-UCS def
        /CMapType 2 def
        1 begincodespacerange
        <0000> <FFFF>
        endcodespacerange
        3 beginbfchar
        <0001> <4F60>
        <0002> <597D>
        <0003> <60A8>
        endbfchar
        \(numericRange)
        endcmap
        CMapName currentdict /CMap defineresource pop
        end
        end
        """
        guard let cmapPlain = cmap.data(using: .ascii) else {
            throw NSError(domain: "PDFEditorTests", code: 11)
        }
        let cmapData = compressed ? try zlibEncodeForFixture(cmapPlain) : cmapPlain
        let filter = compressed ? " /Filter /FlateDecode" : ""

        var pdf = Data("%PDF-1.4\n".utf8)
        var offsets: [Int] = [0]

        func appendObject(_ number: Int, header: String, stream: Data? = nil) {
            while offsets.count <= number { offsets.append(-1) }
            offsets[number] = pdf.count
            pdf.append(contentsOf: "\(number) 0 obj\n".utf8)
            pdf.append(contentsOf: header.utf8)
            if let stream {
                pdf.append(contentsOf: "\nstream\n".utf8)
                pdf.append(stream)
                pdf.append(contentsOf: "\nendstream".utf8)
            }
            pdf.append(contentsOf: "\nendobj\n".utf8)
        }

        let resources = indirectResourcesAndFont
            ? "/Resources 9 0 R"
            : "/Resources << /Font << /F1 4 0 R >> >>"

        appendObject(1, header: "<< /Type /Catalog /Pages 2 0 R >>")
        appendObject(2, header: "<< /Type /Pages /Kids [3 0 R] /Count 1 >>")
        appendObject(
            3,
            header: "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] \(resources) /Contents 8 0 R >>"
        )
        appendObject(
            4,
            header: "<< /Type /Font /Subtype /Type0 /BaseFont /TestCID /Encoding /Identity-H /DescendantFonts [5 0 R] /ToUnicode 7 0 R >>"
        )
        appendObject(
            5,
            header: "<< /Type /Font /Subtype /CIDFontType2 /BaseFont /Helvetica /CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >> /FontDescriptor 6 0 R /DW 1000 /CIDToGIDMap /Identity >>"
        )
        appendObject(
            6,
            header: "<< /Type /FontDescriptor /FontName /Helvetica /Flags 32 /FontBBox [0 -200 1000 900] /ItalicAngle 0 /Ascent 800 /Descent -200 /CapHeight 700 /StemV 80 >>"
        )
        appendObject(
            7,
            header: "<< /Length \(cmapData.count)\(filter) >>",
            stream: cmapData
        )
        appendObject(
            8,
            header: "<< /Length \(contentData.count)\(filter) >>",
            stream: contentData
        )

        if indirectResourcesAndFont {
            appendObject(9, header: "<< /Font 10 0 R >>")
            appendObject(10, header: "<< /F1 4 0 R >>")
        }

        let objectCount = indirectResourcesAndFont ? 10 : 8
        let xrefOffset = pdf.count
        pdf.append(contentsOf: "xref\n0 \(objectCount + 1)\n".utf8)
        pdf.append(contentsOf: "0000000000 65535 f \n".utf8)
        for number in 1...objectCount {
            pdf.append(contentsOf: String(format: "%010d 00000 n \n", offsets[number]).utf8)
        }
        pdf.append(contentsOf: "trailer\n<< /Size \(objectCount + 1) /Root 1 0 R >>\n".utf8)
        pdf.append(contentsOf: "startxref\n\(xrefOffset)\n%%EOF\n".utf8)

        try pdf.write(to: url, options: .atomic)
    }

    private func writeMixedHexTJArrayPDF(
        to url: URL,
        compressed: Bool
    ) throws {
        let hex = Data("100".utf8)
            .map { String(format: "%02X", $0) }
            .joined()
        let streamText = "BT\n/F1 12 Tf\n72 720 Td\n[(Hello ) -20 <\(hex)>] TJ\nET\n"
        try writeCustomContentPDF(to: url, streamText: streamText, compressed: compressed)
    }

    private func writeHexTjPDF(
        to url: URL,
        compressed: Bool
    ) throws {
        let hex = Data("Hello 100".utf8)
            .map { String(format: "%02X", $0) }
            .joined()
        let streamText = "BT\n/F1 12 Tf\n72 720 Td\n<\(hex)> Tj\nET\n"
        try writeCustomContentPDF(to: url, streamText: streamText, compressed: compressed)
    }

    private func writeTJArrayPDF(
        to url: URL,
        compressed: Bool
    ) throws {
        let streamText = "BT\n/F1 12 Tf\n72 720 Td\n[(Hello ) -20 (100)] TJ\nET\n"
        try writeCustomContentPDF(to: url, streamText: streamText, compressed: compressed)
    }

    private func writeCustomContentPDF(
        to url: URL,
        streamText: String,
        compressed: Bool,
        indirectLength: Bool = false
    ) throws {
        guard let plainStream = streamText.data(using: .ascii) else {
            throw NSError(domain: "PDFEditorTests", code: 3)
        }
        let streamData = compressed ? try zlibEncodeForFixture(plainStream) : plainStream

        var pdf = Data("%PDF-1.4\n".utf8)
        var offsets: [Int] = [0]

        func appendObject(_ number: Int, header: String, stream: Data? = nil) {
            offsets.append(pdf.count)
            pdf.append(contentsOf: "\(number) 0 obj\n".utf8)
            pdf.append(contentsOf: header.utf8)
            if let stream {
                pdf.append(contentsOf: "\nstream\n".utf8)
                pdf.append(stream)
                pdf.append(contentsOf: "\nendstream".utf8)
            }
            pdf.append(contentsOf: "\nendobj\n".utf8)
        }

        appendObject(1, header: "<< /Type /Catalog /Pages 2 0 R >>")
        appendObject(2, header: "<< /Type /Pages /Kids [3 0 R] /Count 1 >>")
        appendObject(
            3,
            header: "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>"
        )
        appendObject(4, header: "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")

        let filter = compressed ? " /Filter /FlateDecode" : ""
        if indirectLength {
            appendObject(
                5,
                header: "<< /Length 6 0 R\(filter) >>",
                stream: streamData
            )
            appendObject(6, header: "\(streamData.count)")
        } else {
            appendObject(
                5,
                header: "<< /Length \(streamData.count)\(filter) >>",
                stream: streamData
            )
        }

        let objectCount = offsets.count - 1
        let xrefOffset = pdf.count
        pdf.append(contentsOf: "xref\n0 \(objectCount + 1)\n".utf8)
        pdf.append(contentsOf: "0000000000 65535 f \n".utf8)
        for offset in offsets.dropFirst() {
            pdf.append(contentsOf: String(format: "%010d 00000 n \n", offset).utf8)
        }
        pdf.append(contentsOf: "trailer\n<< /Size \(objectCount + 1) /Root 1 0 R >>\n".utf8)
        pdf.append(contentsOf: "startxref\n\(xrefOffset)\n%%EOF\n".utf8)

        try pdf.write(to: url, options: .atomic)
    }

    private func writeMinimalLiteralTextPDF(
        to url: URL,
        text: String,
        compressed: Bool = false
    ) throws {
        let streamText = "BT\n/F1 12 Tf\n72 720 Td\n(\(text)) Tj\nET\n"
        try writeCustomContentPDF(to: url, streamText: streamText, compressed: compressed)
    }

    private func zlibEncodeForFixture(_ input: Data) throws -> Data {
        var capacity = max(input.count * 2, input.count + 1024)
        while capacity <= 4 * 1024 * 1024 {
            var raw = Data(count: capacity)
            let encodedCount = raw.withUnsafeMutableBytes { destination in
                input.withUnsafeBytes { source in
                    compression_encode_buffer(
                        destination.bindMemory(to: UInt8.self).baseAddress!,
                        capacity,
                        source.bindMemory(to: UInt8.self).baseAddress!,
                        input.count,
                        nil,
                        COMPRESSION_ZLIB
                    )
                }
            }
            if encodedCount > 0 {
                raw.count = encodedCount
                var wrapped = Data([0x78, 0x9C])
                wrapped.append(raw)

                let checksum = adler32ForFixture(input)
                wrapped.append(UInt8((checksum >> 24) & 0xFF))
                wrapped.append(UInt8((checksum >> 16) & 0xFF))
                wrapped.append(UInt8((checksum >> 8) & 0xFF))
                wrapped.append(UInt8(checksum & 0xFF))
                return wrapped
            }
            capacity *= 2
        }
        throw NSError(domain: "PDFEditorTests", code: 2)
    }

    private func adler32ForFixture(_ data: Data) -> UInt32 {
        let modulus: UInt32 = 65_521
        var a: UInt32 = 1
        var b: UInt32 = 0
        for byte in data {
            a = (a + UInt32(byte)) % modulus
            b = (b + a) % modulus
        }
        return (b << 16) | a
    }

}

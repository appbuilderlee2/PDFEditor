# Original macOS PDF Editor

Native macOS PDF Editor (Phase 1). Uses Apple PDFKit + SwiftUI, no copyleft dependencies.

## Stack
- SwiftUI + AppKit
- PDFKit (Apple)
- Phase 1: Page reorder/delete/rotate/save, thumbnail sidebar, toolbar, undo framework
- Phase 2: Content stream editing

## License
MIT — see LICENSE.md. No AGPL/dual-license dependencies in Phase 1.

## Architecture
```
Sources/
  PDFEngine/  # PDFKit wrapper (abstract protocol)
  UI/         # Window, sidebar, toolbar, inspector
  Models/     # Page, DocumentState
  Utils/      # PDFUtilities, Undo adapter
```

# PDFEditor — Native macOS PDF Editor

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
  PDFEditorApp.swift     # App entry & DocumentController
  PDFEngine/
    PDFEngine.swift      # Abstract protocol
    PDFKitEngine.swift   # PDFKit implementation
  UI/
    MainView.swift       # Main window layout
    SidebarView.swift    # Page thumbnail sidebar
    SidebarPageRow.swift # Single page row
    ToolbarItems.swift   # Toolbar controls
  Models/
    Page.swift           # Single page model
    DocumentState.swift  # Undo/Redo state
  Utils/
    DocumentActions.swift # Save/page operations
    PDFUtils.swift       # Page swap utilities
    UndoManagerAdapter.swift # NSUndoManager wrapper
```

## Build
```bash
swift build -c release
```

## Test
```bash
swift test
```

## CI
GitHub Actions workflow runs on `macos-15-intel` runner, building both release and debug configurations.
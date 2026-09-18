# PDFEditor — Third-Party License Summary

## Phase 1 Stack (Safe — No Copyleft Trap)

| Component      | License     | Source / Notes                                      |
|----------------|-------------|----------------------------------------------------|
| Apple PDFKit   | Apple System| Bundled with macOS; no external license burden     |
| Swift / SwiftUI| Apple System| Bundled with macOS                                  |
| Tesseract (optional future OCR) | Apache-2.0 | Bundled binary; no source-level copyleft |
| PDF.js (optional future web fallback) | Apache-2.0 | Embedded; no copyleft |
| OCRmyPDF (optional CLI dependency)  | MPL-2.0 | Source modifications must be released under MPL |

## Deferred / High-Risk (Not in Phase 1)

| Component | License | Risk | Why Deferred |
|-----------|---------|------|--------------|
| MuPDF    | AGPL / Commercial | AGPL copyleft would require entire app open-source | Deferred to Phase 2; commercial option available |
| PDFium   | BSD-3-Clause / Apache-2.0 | Dual-license consistency required; no blocking risk but deferred for simplicity | Could be adopted safely; deferred |

## License Strategy
- Phase 1: Apple PDFKit + SwiftUI only → zero external dependency licensing friction.
- Any future engine (MuPDF, PDFium) must be evaluated by license before code integration.
- This file must be updated before any dependency is added, removed, or swapped.

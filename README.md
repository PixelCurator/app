# PixelCurator (native app)

<!-- OpenSSF Scorecard badge — the api.scorecard.dev badge only resolves for
     PUBLIC repos. Uncomment this once the repo is made public (and flip
     publish_results to true in .github/workflows/scorecard.yml):
[![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/PixelCurator/app/badge)](https://scorecard.dev/viewer/?uri=github.com/PixelCurator/app)
-->

Standalone SwiftUI app for **iPhone, iPad, and Mac** that sorts your photo
library into albums with on-device ML suggestions. Distributed via TestFlight.

This is the native sibling of the macOS Python pipeline (`~/photo-sort/`,
`~/Development/PixelCurator/`). The Python tool is a personal power-tool; this
app is a standalone product where each device works on **its own** photo
library via PhotoKit — no Mac server required.

## Why native (not Flutter), why standalone

- Target is Apple-only (iPhone/iPad/Mac) → Flutter's cross-platform edge is moot,
  while PhotoKit + Core ML access would need platform channels for exactly the
  core features.
- The Python brain is macOS-only and can't ship to iOS: `osxphotos` → **PhotoKit**,
  `photoscript` → PhotoKit writes, PyTorch CLIP → **Apple MobileCLIP (Core ML)**.

## Project layout

```
project.yml                     xcodegen source of truth (the .xcodeproj is generated)
PixelCurator/
  PixelCuratorApp.swift         App entry; injects PhotoController + AlbumManager
  PhotoController.swift         PhotoKit auth, asset fetch, thumbnails  (replaces osxphotos)
  AlbumManager.swift           Read albums + write assets into albums   (replaces photoscript)
  ContentView.swift            Auth-state routing (request / grid / denied)
  PhotoGridView.swift          LazyVGrid of thumbnails, tap to assign
  PlatformImage.swift          UIImage/NSImage bridge
PixelCuratorUITests/
  PhotoAccessUITests.swift     M1 acceptance test: launch → grant → grid renders
```

## Build & run

The `.xcodeproj` is **not** committed — regenerate it from `project.yml`:

```bash
brew install xcodegen          # one time
xcodegen generate

# iOS simulator
xcodebuild -scheme PixelCurator \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build

# macOS (Xcode auto-creates the Mac signing cert on first GUI open)
open PixelCurator.xcodeproj

# Run the M1 acceptance UI test (auto-grants the Photos dialog via Springboard)
xcodebuild test -scheme PixelCurator \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

Bundle id: `yves.vogl.pixelcurator` · Team: `6T5T32GRR3` (Yves Vogl).

## Roadmap

- **M1 — skeleton + critical chain** ✅ PhotoKit read+write, grid, assign-to-album,
  builds for iOS + macOS, UI test green.
- **M2 — on-device brain** ✅ MobileCLIP (Core ML) **S0** embeddings indexed in
  the background, SwiftData store, **find-similar** (cosine top-K), multi-variant
  support + StoreKit IAP scaffold.
- **M3 — sorting flow** ✅ k-NN **album suggestions**, single-card **sorting
  inbox** (accept / skip / pick-other), **undo/redo** of assignments, and
  **corrections-aware** suggestions (assigning against a suggestion feeds back
  as a labeled example — a lightweight on-device "retrain").
- **M4 — TBD.**

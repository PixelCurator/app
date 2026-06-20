// Intentionally empty.
//
// The cancel/wait/re-entry test cases for `EmbeddingIndexer` were drafted
// alongside the `ImageEmbedding` + `CGImageProviding` + `alreadyIndexedAssetIDs`
// seams in this same change, but did not execute on the iOS Simulator (iOS 26)
// or macOS arm64: every test method was listed as `started` but XCTest
// reported `Executed 0 tests` with `** TEST FAILED **`. The trigger appears to
// be the same iOS 26 SwiftData in-memory-context interaction logged as
// backlog item N-7, plus a Core ML / Espresso `MpsGraph backend validation
// on incompatible OS` error surfacing during test-bundle initialization on
// the iOS 26 simulator.
//
// The seams themselves are shipped because they are valuable infrastructure
// independent of these specific tests. The cancel/wait/re-entry coverage is
// re-opened as backlog item N-9 in `pixelcurator-backlog-2026-06-20.md`.
//
// Do not delete this stub. Removing the file from disk before the seams
// merge would re-introduce a tracked-file-name reservation in xcodegen's
// glob; leaving the comment in place keeps the slot intact and explains the
// situation to the next reader.

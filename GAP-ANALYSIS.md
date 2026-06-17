# PixelCurator — Gap Analysis: Python Prototype vs. Native App

Date: 2026-06-17 (corrected)
Status: Honest parity assessment to prioritize a vertical rebuild.

> An earlier version of this document mis-framed the product as a fixed-taxonomy
> classifier and claimed the app had "no automatic classification." That was
> wrong. This version is corrected against the prototype and the app source.

---

## The product model (verified in the prototype)

PixelCurator's USP: **list the user's existing albums, find photos with no
album assignment, and suggest which existing album each unsorted photo belongs
to.** The user's own albums ARE the taxonomy and the training labels — nothing
is predefined.

- `08_import_photos_albums.py:81-94` reads each photo's existing Photos.app
  album memberships and writes them as ground-truth labels.
- `06_retrain.py:85-126` trains a classifier whose **classes are the user's own
  album names** (from corrections + confident assignments) and predicts an
  album + confidence for every photo.
- The 14 hard-coded CLIP-prompt albums in `06_taxonomy.py` were a **one-time
  cold-start bootstrap** (Yves started from ~zero albums). They are NOT the
  product. NSFW (`02_nsfw.py`) and face→person rules were Yves' personal
  bootstrap signals, also out of the core product.

Steady state is active learning: the user confirms/corrects suggestions, and
each correction becomes a new label for the next ranking.

## The app already implements this model

- `AlbumSuggester.suggestions(...)` (`AlbumSuggester.swift:147-159`) enumerates
  the members of **every existing album** as labeled points and ranks them by
  cosine k-NN vote → "which existing album does this photo belong to," with a
  confidence. Corrections are folded in as extra labels (`:161-171`) — the
  lightweight on-device "retrain."
- `SortingCoordinator.filterInbox(...)` (`SortingCoordinator.swift:127-135`):
  the inbox queue = photos that are **embedded AND not in any album** = exactly
  "photos without album assignment."

So the core logic is correct and present. **No classifier rebuild and no
taxonomy input are needed.** The work is to make this model actually reachable
and correct at real scale.

---

## What is actually broken (verified)

| # | Gap | Evidence | Effect |
|---|---|---|---|
| **A** | **500-photo hard cap** | `PhotoController.swift:45-48` (`fetchLimit = 500`) | Only the 500 newest photos load/embed. At 81k photos, most album-member **labels** and most unsorted photos never exist for the app — the model starves. Likely the main reason it felt empty/useless. |
| **B** | **Photo-tap shows a dumb album list** | `PhotoGridView.swift:114-120` (`confirmationDialog` over `albums.albums.prefix(8)`) | The reported "dialog with irrelevant albums." The smart suggester is ignored here; it lives only in the Sorting Inbox. |
| **C** | **The smart flow is buried** | Sorting Inbox is behind a toolbar button | The inbox IS the USP but is not the centerpiece. |
| **D** | **Thin review UX** | single-card; no batch, per-album view, or confidence buckets | vs. the prototype's richer review (`server.py`). Secondary. |

Out of scope (were personal bootstrap, not the USP): NSFW detection, face→person
albums, fixed taxonomy prompts.

---

## Rebuild order (expose + scale the existing model, verified in the running app)

1. **A — remove the 500 cap**: load the full library; rely on the existing
   incremental indexer (skips already-embedded, batch-saves). Biggest lever.
2. **B/C — make suggestions the primary action**: replace the photo-tap album
   list with ranked suggestions from `AlbumSuggester`, and make the Sorting
   Inbox the app's centerpiece.
3. **D — deepen the review UX** (batch / per-album / confidence buckets) as a
   follow-up.

## Reuse, do not rebuild

`AlbumSuggester`, `SortingCoordinator`, `EmbeddingIndexer`, the embedding store,
similarity, `AlbumManager` write-back, and `DecisionLog` undo are the right
primitives and already wired — the model just needs full-library data (A) and a
front-and-center entry point (B/C).

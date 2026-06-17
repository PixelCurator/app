# PixelCurator — Gap Analysis: Python Prototype vs. Native App

Date: 2026-06-17
Status: Honest parity assessment to prioritize a vertical rebuild.

> **Verification caveat.** The prototype inventory is verified by reading the
> running pipeline's code. The app's "wired" verdicts below are from *code-path
> tracing only* — the app was crashing until 2026-06-16 (EmbeddingStore
> `#Predicate` trap, fixed in 6f664d6) and boots slowly (4 ModelContainers).
> "Wired" here means the call path exists in source, NOT that it works in the
> running app. Each capability is only "done" once demonstrated in the running
> app.

---

## The one paragraph that matters

The Python prototype is a **classifier-first bulk sorter**: it automatically
assigns *every* photo to a taxonomy album using three signals (zero-shot CLIP
text prompts, NudeNet NSFW, Apple face names), attaches a confidence, and the
human's job is to **review and correct pre-made buckets**. "The machine sorted
81k photos; you fix the mistakes."

The app is a **cold-start manual sorter**: it has **no automatic
classification**. The human sorts photos one at a time; the app only suggests
albums by k-NN similarity to *already-sorted* photos. With zero sorted photos
there are zero suggestions. The reported "irrelevant albums dialog" is exactly
this gap — tapping a photo shows the first 8 *existing* albums (arbitrary),
because there is no classifier to suggest from.

**That inverted model is THE gap.** Embeddings, similarity, album write-back,
undo all exist. The thing that makes the prototype useful — automatic taxonomy
classification with a confidence convention — is entirely absent.

---

## Capability parity table

| # | Capability | Prototype | App | Verdict |
|---|---|---|---|---|
| 1 | **Inventory / library scan** | `inventory.py` via osxphotos → CSV | PhotoController + PhotoGridView (PhotoKit) | ✅ Parity (different source, same role) |
| 2 | **CLIP image embeddings** | OpenAI CLIP ViT-B-32, 512-dim, MPS | MobileCLIP S0 (+S1/S2/B), 512-dim, Core ML | ✅ Parity (app's on-device model is the right call) |
| 3 | **NSFW detection** | NudeNet v3, explicit/nude/safe + conf | — | ❌ **ABSENT** |
| 4 | **Face → person albums** | Apple face names → Yves/Coven Call/pets/Family | — (app has no Vision face usage) | ❌ **ABSENT** |
| 5 | **Zero-shot taxonomy classifier** | 14 CLIP text-prompt albums, softmax, threshold | — | ❌ **ABSENT** (core of the prototype) |
| 6 | **Confidence convention** | ≥0.80 main · 0.50–0.80 `-unsure` · <0.50 Diverses | — | ❌ **ABSENT** |
| 7 | **Multi-membership + priority primary** | photo ∈ many albums; PRIORITY picks primary | single album per assign | ❌ **ABSENT** |
| 8 | **Album write-back to library** | photoscript create/add, batches of 200 | AlbumManager.assign() (PhotoKit) | ✅ Parity (simpler: no folders) |
| 9 | **Review UX — by-album contact sheets** | per-album HTML grids, conf badges, paged | — (only a flat photo grid) | ❌ **ABSENT** |
| 10 | **Review UX — modal reassign** | dropdown + find-similar + batch select | confirmationDialog (8 albums) — no suggestions | ⚠️ Weak placeholder |
| 11 | **Find similar** | `/api/similar` cosine top-N | SimilaritySearch + context menu | ✅ Wired (verify in running app) |
| 12 | **Sorting inbox (new/unsorted)** | `07_incremental` detect→process; Inbox.html | SortingCoordinator: "not in any album" queue, k-NN suggest | ⚠️ Wired but suggestions are cold-start-empty without a classifier |
| 13 | **Undo / redo** | server stack (1 level), 3 action types | DecisionLog (multi-level) | ✅ Wired (app is richer; verify in app) |
| 14 | **Learn from corrections** | LogisticRegression retrain (weak+strong labels) | k-NN re-vote using CorrectionStore | ⚠️ Different mechanism, weaker; no trained model |
| 15 | **Album rename / merge** | `/api/rename-album`, `/api/merge-album` | — | ❌ ABSENT |
| 16 | **Trash flow** | reassign to "Thrash", never written back | — | ❌ ABSENT |

Legend: ✅ parity · ⚠️ partial/weak/unverified · ❌ absent

---

## The prototype's classification logic (the part to port)

Three signals feed each photo's album memberships, then a priority picks the
primary:

1. **Face → person** (exact name match from Apple face data):
   `Yves Vogl` → "Yves"; band set → "Coven Call"; pet names → pet albums;
   any other named person → "Family & Friends".
2. **NSFW** (NudeNet): `explicit_conf ≥ 0.80` → "Pornografie" (≥0.50 →
   `-unsure`); `nude_conf ≥ 0.80` → "Nacktheit" (≥0.50 → `-unsure`).
3. **Zero-shot CLIP** (14 albums, each = averaged text-prompt encoding):
   `softmax(sim × 100)`; `≥0.80` → main album, `≥0.50` → `<album>-unsure`,
   else nothing.

Confidence convention (unified across all stages):
`CONF_MAIN = 0.80`, `CONF_UNSURE = 0.50`.

Primary album = highest `PRIORITY` among memberships (NSFW > Coven Call > pets >
Yves > Family > topical > "Diverses" fallback).

**On-device portability:**
- Zero-shot CLIP taxonomy → directly portable. MobileCLIP has a text encoder;
  encode the prompts once, cosine vs. image embeddings, same thresholds. This is
  the single highest-value port.
- Faces → **better** on the app: Apple's `Vision` (`VNDetectFaceRequest` /
  `VNGenerateFaceprintRequest`) + PhotoKit person data. No osxphotos needed.
- NSFW → needs a Core ML NSFW model (NudeNet is ONNX; convert, or use an
  alternative). Medium effort.

---

## Recommended rebuild order (vertical slices, each verified in the running app)

Priority is mine to set (per your direction); rationale = "restore the
prototype's usefulness fastest."

1. **Zero-shot CLIP taxonomy classifier** — biggest payoff. Encode prompt
   albums with MobileCLIP text encoder; classify the whole library; apply the
   0.80/0.50 convention; write to PhotoKit albums (+`-unsure`). This alone turns
   the app from "manual sorter" into "the machine sorted your photos."
2. **By-album review UI** — replace the flat grid + irrelevant-album dialog with
   per-album views showing the classifier's buckets, confidence badges, and a
   real "move / confirm / trash" action. Fix the photo-tap.
3. **Face → person albums** via Vision + PhotoKit person data.
4. **NSFW** via a Core ML model.
5. **Multi-membership + priority primary**, then **correction learning** (k-NN
   is already there; decide whether a trained classifier is worth it).

Slices 1–2 restore the perceived product. 3–5 close remaining parity.

---

## What already exists and should be reused, not rebuilt

- MobileCLIP embedding + SwiftData store + background indexer (slices 1, 3
  depend on it).
- Similarity / find-similar.
- AlbumManager write-back + DecisionLog undo/redo.
- CorrectionStore (feeds slice 5).

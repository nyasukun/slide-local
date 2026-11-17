# Translation UX verification

## Outcome

Document-centered SwiftUI workflow implemented. Persistent sequential queue retained. Ollama CLI service work (`c0142f5`) merged into `ux/translation-workflow`; the application no longer starts the GUI. Changes are local; no UX branch push or installation has been performed.

## Terra reviews

1. UX inventory and behavior audit.
2. Independent design/builder review: durable reset authorization, cancellation, export truthfulness and operation snapshots added to design.
3. Intermediate implementation review: queue-write failure recovery, cancellation during failed model lookup and historical progress corrected with failing-then-passing regressions.
4. Whole-branch review: no Critical findings; Important final-build cancellation, chat persistence boundary and running-request settings corrected with failing-then-passing regressions.
5. CLI integration review: no Critical or Important integration findings.

These were source reviews, not independently executed GUI acceptance tests.

## Executed verification

- Full native suite: original PPTX, storage/migration, ZIP64, FIFO, pause/stop/restart, privacy and reentrancy checks; new reset approval, old-queue hold, setup/final-build stop, queue-write retry, immutable export, no-overwrite, fixed StudioModel targets, drafts, chat deletion/cancellation and active-settings tests.
- CLI resolver/startup checks: 9 Python tests.
- Native AppKit/SwiftUI bitmaps at 1100×760 and 1450×760, with the question panel on/off. Inspected 1100×760 bitmap and confirmation layout. Bitmaps are rendering evidence, not interactive accessibility tests.
- `./build-native.command --stage`: app compilation, ad-hoc signing and strict signature verification.
- Renderer privacy smoke: IPv4/IPv6 and unrelated-file access denied; benign PDF/PNG generated.
- `./tests/run-offline-check.command`: dedicated CLI Ollama on test port 11435, cloud disabled, non-loopback IP blocked, existing model store read-only; two synthetic decks translated sequentially by PLaMo, Qwen factual document question, editable PPTX and LibreOffice/PDFKit preview. Normal port 11434 was not stopped or reconfigured.

## Remaining manual acceptance

OS save/overwrite dialog clicks, keyboard-only navigation/focus, VoiceOver, long-list scrolling, and clicking real destructive confirmation dialogs. No user's real documents or conversations were used in tests.

## Deferred minor findings

1. Historical retry rows show stored settings but not a separate current-versus-history difference for non-reset notes/fit changes.
2. At startup, a reachable Ollama with zero models gets no-model guidance from refresh, then a generic ready notice can replace it. A manual refresh restores the no-model guidance; unavailable models remain visibly unavailable and execution stays blocked.

## Implementation rulings

1. Continued implementation while Git identity was initially absent rather than inventing it. Existing repository identity later became available and all changes were committed. Cost was temporarily uncommitted progress, now resolved.
2. Applied intermediate review fixes within Tasks 1–2 rather than creating unrelated tasks, because they enforce those contracts. Cost: coarser task boundaries.
3. Committed Tasks 1–2 together and Tasks 3–5 together after identity became available; shared files had interleaved changes. Cost: coarser commit boundaries; individual RED/GREEN evidence remains recorded.
4. Completed answers enter a short non-cancellable “回答を保存中” phase. Stop/selection are disabled and the engine rejects cancelled recording tasks. Cost: cannot stop during the short atomic persistence phase; the UI no longer falsely accepts it.
5. Unperformed desktop checks remain explicitly unverified rather than being inferred from model tests or bitmaps. Cost: interaction defects can remain until manual acceptance.
6. Synthetic non-reset confirmation bitmap is layout evidence only; destructive authorization is tested in the model and engine, not by clicking the dialog. Cost: dialog wiring remains a manual check.
7. GUI startup was temporarily excluded while its separate branch was owned by another chat. It was subsequently removed by the merge and covered by CLI integration review and tests. No remaining cost from that exclusion.

## Integration boundary

Base: local `main` at `12302e8`. Completed combined work is on `ux/translation-workflow`. Do not push, replace an installed application, or alter existing Ollama services without a separate request. Final merge into `main` is the user's next integration choice.

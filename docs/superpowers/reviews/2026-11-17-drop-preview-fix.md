# Drop responsiveness and explicit preview — corrective change

## Report and investigation

The user reported a stuck Finder drag overlay and LibreOffice apparently attempting to run. A sample of the installed app showed the main thread in its normal idle event loop, and no LibreOffice/soffice process was present at sampling. This does not prove the original report's LibreOffice causal path; it was not reproduced with the user's real document.

The existing drop handler requested a generic URL object, set no immediate busy state, did not clear the drag overlay, silently ignored failed URL resolution, and had no deadline for a missing callback. A regression test failed on the missing immediate progress/lock/overlay reset.

## Changes

- Load only raw `public.file-url` data rather than requesting object conversion or document/file representations.
- Begin every asynchronous file-URL data request synchronously inside the drop callback, then await only the results; preserve source lifetime and show immediate feedback while locking duplicate document actions.
- Clear drag targeting on acceptance/rejection/completion. Report failures and start all 15-second provider deadlines together, rather than adding one timeout per file; late callbacks cannot resume twice.
- Preserve partial import behavior and common settings for multi-file drops.
- Reset new document selection to text mode, with no preview image loading until the user chooses preview.
- Keep sandboxed LibreOffice rendering behind the explicit preview-create/update action. Import, selection, translation and export do not invoke the renderer.
- Release 2.0.2, build 5.

## Verification scope

The full native suite, CLI tests, drop regression tests and stage build passed. Drop tests use real item-provider callbacks and real engine/storage/PPTX operations, fake local inference, and a renderer spy. The tests cover success, invalid URL feedback, deadline cancellation, late callback, zero render calls on import/translation/export and one on explicit preview.

Actual Finder mouse dragging with the reported document and its macOS source process remains a manual acceptance check; no real document content was used. No unrelated LibreOffice process was terminated.

## Terra review fixes

The focused review found that starting provider loading in a later Task risks outliving the drop callback, and that sequential requests could accumulate deadlines. Both were addressed by starting all representation loads before the callback returns, storing completed results, and awaiting those results afterward. Tests model callback-scoped provider availability, four simultaneous stalled providers, a valid provider alongside them, native NSURL providers with Japanese/spaces/reserved characters, and prior-error isolation. Project switching back to text mode is intentional and tested separately.

Terra's focused follow-up found no remaining Critical or Important defects. Its minor test-assertion gap was corrected to require a timeout failure for every stalled provider, not just a bounded elapsed time. Actual Finder interaction remains outstanding.

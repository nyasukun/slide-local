# Native tests

Python is used only to generate synthetic decks and independently inspect OOXML. The installed app has no Python dependency. No real documents or historical results are included.

Use Python 3.11 or newer (required by the pinned Pillow version). Prepare development dependencies while online:

```sh
python3 --version
python3 -m venv .venv
.venv/bin/python -m pip install -r requirements-test.txt
./tests/run-native-tests.command
```

The default suite checks PPTX editing, unchanged ZIP members, charts and embedded workbooks, ZIP64 sparse offsets and large member counts, migration, locks, cache keys, sequential queues, lifecycle/restart, chat state, and local-only HTTP preflight with a mock URLProtocol. It does not call a real Ollama server or render untrusted documents. The ZIP64 check creates a sparse file with a logical size over 4GiB; it is not a 4GiB download.

CAT output tests also cover isolated system instructions, conservative removal of known output labels/postscripts, preservation of source notes and paragraphs, rejection of ambiguous commentary/instruction echoes, and HTTP preflight. Regeneration tests cover explicit/stale confirmation, cache versioning/bypass, retaining prior manual text on failure, excluded notes, cancel/restart, legacy queue JSON, and Studio confirmation/cancellation/double-click behavior. `NativeIntegration.swift` accepts `--regenerate` for the optional real-model path; it replaces a test-owned manual sentinel only after explicit regeneration consent.

Gemma tests cover its single-user translation prompt, one-translation instruction, language names/codes for all UI languages, short-heading detection, same-language/numeric preservation, bounded context, old generic-cache isolation, privacy/truncation/empty-output errors, exclusion from chat, and opening old CAT projects without rewriting saved edits/history. Regeneration tests run for both CAT and Gemma. A dedicated engine test verifies <=480-byte Gemma chunks, a fixed 1024-token output reserve, retention after a later chunk fails, no partial cache, and full-source retry. `NativeGemmaSmoke.swift` is an opt-in real `OllamaClient` check taking a synthetic JSON corpus and an output path; it uses the same 480-byte splitting, saves translations for source/output review, and does not self-grade semantic accuracy.

UX regressions additionally check durable approval before translation resets, stale approvals, excluded-note edits, setup cancellation (including lookup failure), legacy queued requests held for confirmation, recovery without repeating reset, queue persistence failure/retry, historical progress, immutable export files, non-overwriting batch saves, whitespace-only drafts, fixed StudioModel action targets, partial saves, duplicate confirmation, historical retry settings, missing models, chat limits, and deletion generations. Inference is a controlled fake; real storage and engine/model paths run.

Drop regressions use raw `public.file-url` item-provider data, immediate busy feedback and overlay reset, invalid URL rejection, a stalled-provider deadline with late callback, and a renderer spy proving no rendering during import/translation/export and exactly one render after an explicit preview request. They do not automate a Finder mouse drag or reproduce every OS drag-source conversion behavior.

For a native AppKit/SwiftUI rendering smoke check using only synthetic material:

```sh
NATIVE_LAYOUT_CHECK=1 ./tests/run-native-tests.command
```

This produces ignored PNGs under `.cache/native-tests/layout-results/` at 1100×760 and 1450×760 with the question panel on/off. It confirms rendering at the requested bounds, not keyboard interaction, VoiceOver, OS save panels, real inference or renderer availability. Inspect images for clipping and perform those checks on a real macOS desktop before claiming complete GUI acceptance. It does not open the user's documents or use their application data.

The suite also runs dependency-free Python tests for CLI executable resolution and narrow source regressions for the UI startup (not a GUI acceptance test). Run just these with `python3 -m unittest discover -s tests -p 'test_*cli*.py'`.

`reference_pptx.py` is a read-only independent OOXML inspector used as an oracle. There is no legacy web backend in this repository.

## Optional preview test

After installing LibreOffice:

```sh
./tests/run-privacy-preview-check.command
```

It checks that the renderer policy rejects TCP connections to test-owned IPv4/IPv6 loopback listeners and reading a dummy file outside its scratch directory, then renders a benign generated slide. It does not contact an Internet endpoint. Some agent sandboxes cannot apply a nested macOS sandbox profile; the check can be run from a normal local Terminal. The renderer policy is part of the behavior under test.

## Optional offline integration

Requires an Ollama CLI (normally `brew install ollama`), `/Applications/LibreOffice.app`, existing models under `~/.ollama/models`, and the exact names `translategemma:12b-it-q4_K_M` / `qwen3.5:4b`. Custom model directories are not supported by this test harness. The GUI app is not required.

The executable is resolved from `OLLAMA_BIN`, then `ollama` on the caller's `PATH`, then the legacy `/Applications/Ollama.app/Contents/Resources/ollama`. An explicitly set but empty, missing or non-executable `OLLAMA_BIN` is an error, not a reason to silently select another binary. Quote paths containing spaces:

```sh
OLLAMA_BIN="/path with spaces/ollama" ./tests/run-offline-check.command
```

```sh
./tests/run-offline-check.command
```

The harness starts its own Ollama at `127.0.0.1:11435`, gives it read-only access to existing model files, and blocks non-loopback IP traffic with a macOS sandbox. It does not stop or reconfigure the ordinary server at 11434. A test-only client copy changes three literal port values; installed application code is untouched.

It translates two generated one-slide decks sequentially, saves editable PPTX, asks a factual question, checks conversation storage, and generates PDF/PNG previews in a separate helper with the production renderer sandbox. Inference and preview are checked in separate phases. Temporary documents and the dedicated server are cleaned up. A local result goes to ignored `tests/output/offline-verification.json`; it may contain local paths and is not suitable for publication.

This does not switch off Wi-Fi or establish that unrelated apps have no Internet traffic. Also follow the offline GUI acceptance steps in [INSTALL.md](../INSTALL.md) when testing the full user flow.

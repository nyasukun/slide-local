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

The suite also runs dependency-free Python tests for CLI executable resolution and narrow source regressions for the UI startup (not a GUI acceptance test). Run just these with `python3 -m unittest discover -s tests -p 'test_*cli*.py'`.

`reference_pptx.py` is a read-only independent OOXML inspector used as an oracle. There is no legacy web backend in this repository.

## Optional preview test

After installing LibreOffice:

```sh
./tests/run-privacy-preview-check.command
```

It checks that the renderer policy rejects TCP connections to test-owned IPv4/IPv6 loopback listeners and reading a dummy file outside its scratch directory, then renders a benign generated slide. It does not contact an Internet endpoint. Some agent sandboxes cannot apply a nested macOS sandbox profile; the check can be run from a normal local Terminal. The renderer policy is part of the behavior under test.

## Optional offline integration

Requires an Ollama CLI (normally `brew install ollama`), `/Applications/LibreOffice.app`, existing models under `~/.ollama/models`, and the exact names `plamo-translate:0.8b` / `qwen3.5:4b`. Custom model directories are not supported by this test harness. The GUI app is not required.

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

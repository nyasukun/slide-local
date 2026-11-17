"""Locate the Ollama CLI for the isolated offline harness (never launch the GUI)."""
from collections.abc import Mapping
import os
from pathlib import Path
import shutil

GUI_BINARY = "/Applications/Ollama.app/Contents/Resources/ollama"


def resolve_ollama_binary(environ: Mapping[str, str]) -> str:
    if "OLLAMA_BIN" in environ:
        candidate = environ["OLLAMA_BIN"]
        if candidate and Path(candidate).is_file() and os.access(candidate, os.X_OK):
            return str(Path(candidate).resolve())
        raise RuntimeError("OLLAMA_BIN must name an existing executable Ollama CLI file.")
    candidate = shutil.which("ollama", path=environ.get("PATH", ""))
    if candidate:
        return str(Path(candidate).resolve())
    if Path(GUI_BINARY).is_file() and os.access(GUI_BINARY, os.X_OK):
        return str(Path(GUI_BINARY).resolve())
    raise RuntimeError("Ollama CLI not found. Run brew install ollama or set OLLAMA_BIN to its executable path.")

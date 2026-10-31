"""Fail initialization when required integrations cannot load in the selected environment."""
import os
from pathlib import Path
import sys

from pm.environments import project_python

selected = project_python(Path("/opt/hermes"))
if Path(sys.executable) != selected:
    os.execv(str(selected), [str(selected), __file__])

from hermes_cli.config import load_config
from plugins.memory import load_memory_provider

if load_config().get("memory", {}).get("provider") == "mnemosyne":
    from mnemosyne.core import embeddings

    provider = load_memory_provider("mnemosyne")
    if provider is None or not provider.is_available():
        raise SystemExit("Mnemosyne is configured but its memory provider cannot load")
    # Fetch the local embedding model now, so a failed download stops startup
    # instead of silently degrading recall to keyword search.
    if not embeddings.available() or embeddings.embed_query("caduceus") is None:
        raise SystemExit("Mnemosyne's local embedding model is unavailable")
    print("[caduceus] Mnemosyne provider and embedding model available")

if load_config().get("web", {}).get("extract_backend") == "iris":
    from tools import web_tools

    web_tools._ensure_web_plugins_loaded()
    provider = web_tools._registered_web_provider("iris")
    if provider is None or not provider.is_available():
        raise SystemExit("Iris is configured but its web_extract provider cannot load")
    import playwright  # noqa: F401  Browser fallback for script-rendered pages.
    print("[caduceus] Iris provider and dependencies available")

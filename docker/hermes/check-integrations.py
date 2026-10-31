"""Exercise Hermes's configured local backends, without public-provider rescue.

Mnemosyne checks write to a throwaway Hermes home, so the operator's memory
database is never touched.
"""
import asyncio
import json
import logging
import os
from pathlib import Path
import sys
import tempfile
from urllib.parse import urlparse
from uuid import uuid4

sys.path.insert(0, "/opt/hermes")
from pm.environments import project_python

selected = project_python(Path("/opt/hermes"))
if Path(sys.executable) != selected:
    os.execv(str(selected), [str(selected), __file__])

from hermes_cli.config import get_env_value, load_config
from hermes_constants import reset_hermes_home_override, set_hermes_home_override
from plugins.memory import load_memory_provider
from tools import web_tools

logging.basicConfig(level=logging.WARNING)


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def local_url(url, hostname):
    parsed = urlparse(url or "")
    require(parsed.scheme == "http" and parsed.hostname == hostname,
            f"Expected the local {hostname} service; check the backend configuration")


def check_search():
    require(web_tools._get_search_backend() == "searxng", "web.search_backend must be searxng")
    local_url(get_env_value("SEARXNG_URL"), "searxng")
    provider = web_tools._registered_web_provider("searxng")
    require(provider is not None, "SearXNG provider did not load")
    response = provider.search("Python programming language official documentation", limit=3)
    require(response.get("success"), response.get("error") or "SearXNG search failed")
    rows = response.get("data", {}).get("web", [])
    require(rows, "SearXNG returned no results; inspect its upstream engine logs")
    return f"{len(rows)} search results through the local SearXNG service"


def check_extract():
    require(web_tools._get_extract_backend() == "iris", "web.extract_backend must be iris")
    provider = web_tools._registered_web_provider("iris")
    require(provider is not None and provider.is_available(), "Iris provider did not load")
    rows = asyncio.run(provider.extract(
        ["https://example.com", "https://excalidraw.com/", "http://169.254.169.254/"]))
    require(len(rows) == 3, "Iris did not return every requested page")
    for row in rows[:2]:
        require(not row.get("error"), f"{row['url']}: {row.get('error')}")
        require((row.get("content") or "").strip(), f"Iris returned an empty page for {row['url']}")
    renderers = [row.get("metadata", {}).get("renderer") for row in rows[:2]]
    require(renderers == ["http", "browser"],
            f"Expected a direct fetch and a browser render, got {renderers}")
    require("private or internal" in (rows[2].get("error") or ""),
            "Iris did not block a cloud metadata address")
    return "direct fetch, browser render and private-address block through local Iris"


def initialize_mnemosyne(home, session_id, providers, scope):
    provider = load_memory_provider("mnemosyne")
    require(provider is not None and provider.is_available(),
            "Mnemosyne plugin or its dependencies are unavailable")
    providers.append(provider)
    # The throwaway home has no config.yaml, so pass the operator's scope.
    provider.initialize(session_id, platform="tui", hermes_home=home, default_scope=scope)
    require(provider._beam is not None, "Mnemosyne session initialization failed; inspect Hermes logs")
    require(Path(provider._beam.db_path).resolve().is_relative_to(Path(home).resolve()),
            "Mnemosyne opened the operator's database; refusing to write")
    return provider


def check_memory():
    from mnemosyne.core import embeddings

    require(load_config().get("memory", {}).get("provider") == "mnemosyne",
            "memory.provider must be mnemosyne")
    require(embeddings.available(), "Mnemosyne's local embedding model is unavailable")
    scope = load_config().get("memory", {}).get("mnemosyne", {}).get("default_scope", "session")
    require(scope == "global",
            "memory.mnemosyne.default_scope must be global, or memories stay in their session")
    token = uuid4().hex[:12]
    marker = f"Caduceus integration smoke check reference token: {token}."
    providers = []
    with tempfile.TemporaryDirectory(prefix="caduceus-smoke-") as home:
        # Mnemosyne refuses writes for a home other than the current one.
        override = set_hermes_home_override(home)
        try:
            writer = initialize_mnemosyne(home, f"caduceus-smoke-{token}-write", providers, scope)
            # No explicit scope: the agent's own saves rely on the default too.
            stored = json.loads(writer.handle_tool_call(
                "mnemosyne_remember", {"content": marker, "importance": 0.9}))
            require(stored.get("status") == "stored",
                    f"Mnemosyne did not store the smoke-check memory: {stored}")

            reader = initialize_mnemosyne(home, f"caduceus-smoke-{token}-read", providers, scope)
            require(reader._beam.session_id != writer._beam.session_id,
                    "Mnemosyne did not create a separate recall session")
            recalled = reader.handle_tool_call("mnemosyne_recall", {"query": marker, "limit": 5})
            require(token in recalled,
                    "Mnemosyne stored the memory but cross-session recall did not return it")
            # Different wording from the stored text needs embedding-based recall.
            paraphrased = reader.handle_tool_call(
                "mnemosyne_recall", {"query": "which code did the setup test record?", "limit": 5})
            require(token in paraphrased,
                    "Recall needs exact words; set MNEMOSYNE_POLYPHONIC_RECALL=1")
            return "memory stored and recalled from a second session, including by meaning"
        finally:
            for provider in reversed(providers):
                provider.shutdown()
            reset_hermes_home_override(override)


def safe_error(error):
    text = str(error)
    for name, value in os.environ.items():
        if len(value) > 8 and any(part in name.upper() for part in ("KEY", "TOKEN", "PASSWORD", "SECRET")):
            text = text.replace(value, "[redacted]")
    return text[:1000]


def main():
    web_tools._ensure_web_plugins_loaded()
    failures = 0
    for name, check in (("SearXNG", check_search), ("Iris", check_extract), ("Mnemosyne", check_memory)):
        print(f"Checking {name}...", flush=True)
        try:
            print(f"  PASS: {check()}", flush=True)
        except Exception as error:
            failures += 1
            print(f"  FAIL: {safe_error(error)}", flush=True)
    return bool(failures)


if __name__ == "__main__":
    raise SystemExit(main())

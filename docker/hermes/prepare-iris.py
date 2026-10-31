"""Install the bundled Iris plugin or refresh a copy managed by Caduceus."""
import hashlib
from pathlib import Path
import shutil
import subprocess

from hermes_cli.config import load_config
from hermes_constants import get_hermes_home


NAME = "iris"
SOURCE = Path("/opt/caduceus/plugins/iris")
MARKER = ".caduceus-managed"


def digest(root: Path) -> str:
    sha = hashlib.sha256()
    for path in sorted(p for p in root.rglob("*") if p.is_file() and "__pycache__" not in p.parts):
        sha.update(path.relative_to(root).as_posix().encode() + b"\0" + path.read_bytes())
    return sha.hexdigest()


def hermes(*args: str) -> None:
    subprocess.run(["hermes", "plugins", *args], check=True)


def main() -> None:
    config = load_config()
    if config.get("web", {}).get("extract_backend") != NAME:
        return

    target = get_hermes_home() / "plugins" / "web" / NAME
    marker = target / MARKER
    if target.exists() and not marker.is_file():
        print("[caduceus] Keeping user-managed Iris plugin", flush=True)
        return

    enabled = f"web/{NAME}" in (config.get("plugins", {}).get("enabled") or [])
    wanted = digest(SOURCE)
    if marker.is_file() and marker.read_text().strip() == wanted:
        if not enabled:
            hermes("enable", NAME)
        return

    print("[caduceus] Preparing Iris from the bundled plugin", flush=True)
    if enabled:
        # Disabling first makes enable re-resolve any changed dependencies.
        hermes("disable", NAME)
    shutil.rmtree(target, ignore_errors=True)
    shutil.copytree(SOURCE, target, ignore=shutil.ignore_patterns("__pycache__"))
    marker.write_text(wanted + "\n")
    hermes("enable", NAME)


if __name__ == "__main__":
    main()

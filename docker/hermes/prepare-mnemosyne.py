"""Install Mnemosyne from the catalog or refresh a pin managed by Caduceus."""
import subprocess
import sys

from hermes_cli.memory_provider_migration import configured_provider, provider_present
from hermes_cli.plugins_cmd_git import _read_install_metadata
from hermes_constants import get_hermes_home


NAME = "mnemosyne"


def main(revision: str) -> None:
    home = get_hermes_home()
    if configured_provider(home) != NAME:
        return

    force = False
    if provider_present(NAME, home):
        record = _read_install_metadata().get(NAME, {})
        # Caduceus always installs with an explicit --ref, which records a pin.
        if record.get("catalog", {}).get("name") != NAME or record.get("pinned") is not True:
            print("[caduceus] Keeping user-managed Mnemosyne plugin", flush=True)
            return
        if record.get("revision") == revision:
            return
        force = True

    print("[caduceus] Preparing Mnemosyne from the Hermes plugin catalog", flush=True)
    command = ["hermes", "plugins", "install", NAME,
               "--ref", revision, "--yes-deps", "--enable"]
    if force:
        command.append("--force")
    subprocess.run(command, check=True)


if __name__ == "__main__":
    main(sys.argv[1])

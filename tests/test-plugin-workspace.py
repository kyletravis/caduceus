#!/usr/bin/env python3
"""Exercise real Hermes workspace generation and offline uv resolution.

Run with Hermes's PM interpreter in an isolated container. Set
CADUCEUS_HERMES_SOURCE to a mounted checkout to test a patched workspace module
while using the image's already installed, pinned toolchain.
"""

import os
from pathlib import Path
import subprocess
import sys
import tempfile
import tomllib
import unittest


sys.path.insert(0, "/opt/hermes")
from pm._uv import _toolchain

TOOLCHAIN = _toolchain(realize=False)
if TOOLCHAIN is None:
    raise SystemExit("Hermes's pinned uv and Python must already be installed")

if source := os.environ.get("CADUCEUS_HERMES_SOURCE"):
    import pm

    sys.path.insert(0, source)
    pm.__path__.insert(0, str(Path(source) / "pm"))

from pm.workspace import _generate_pyproject


class PluginWorkspaceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="caduceus-plugin-workspace-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.core = self.root / "core"
        self.plugin = self.root / "plugin"
        self.workspace = self.root / "workspace"
        self.core.mkdir()
        self.plugin.mkdir()
        (self.core / "pyproject.toml").write_text(
            '[project]\nname = "hermes-agent"\nversion = "0.22.5"\n'
            'requires-python = ">=3.11"\ndependencies = []\n'
            '[tool.uv]\npackage = false\n'
        )

    def generate(self, requirement):
        manifest = (
            '[project]\nname = "fixture-plugin"\nversion = "1.0.0"\n'
            'requires-python = ">=3.11"\ndependencies = []\n'
            '[dependency-groups]\n'
            f'test = ["{requirement}", {{include-group = "shared"}}]\n'
            'shared = ["fixture-helper>=1,<2"]\n'
            '[tool.uv]\npackage = false\n'
            '[tool.uv.sources]\nfixture-helper = {path = "helper"}\n'
        )
        (self.plugin / "pyproject.toml").write_text(manifest)
        helper = self.plugin / "helper"
        helper.mkdir()
        (helper / "pyproject.toml").write_text(
            '[project]\nname = "fixture-helper"\nversion = "1.0.0"\n'
            'requires-python = ">=3.11"\ndependencies = []\n'
            '[tool.uv]\npackage = false\n'
        )
        original = (self.plugin / "pyproject.toml").read_bytes()
        _generate_pyproject([self.plugin], self.workspace, source=self.core)
        member = next((self.workspace / "plugin-sources").iterdir())
        document = tomllib.loads((member / "pyproject.toml").read_text())
        self.assertEqual(document["dependency-groups"], tomllib.loads(manifest)["dependency-groups"])
        self.assertEqual(document["tool"]["uv"]["sources"]["fixture-helper"], {"path": "helper"})
        self.assertEqual((self.plugin / "pyproject.toml").read_bytes(), original)
        return document

    def lock(self):
        uv, python = TOOLCHAIN
        return subprocess.run(
            [str(uv), "lock", "--offline", "--directory", str(self.workspace), "--python", str(python)],
            env={**os.environ, "UV_CACHE_DIR": str(self.root / "cache"), "UV_PYTHON_DOWNLOADS": "never"},
            capture_output=True,
            text=True,
            timeout=30,
        )

    def test_development_git_dependency_uses_current_hermes_workspace(self):
        self.generate(
            "hermes-agent @ git+https://example.invalid/hermes-agent@"
            "0123456789012345678901234567890123456789"
        )
        result = self.lock()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        lock = tomllib.loads((self.workspace / "uv.lock").read_text())
        hermes = next(package for package in lock["package"] if package["name"] == "hermes-agent")
        self.assertEqual(hermes["version"], "0.22.5")
        self.assertNotIn("git", hermes["source"])
        helper = next(package for package in lock["package"] if package["name"] == "fixture-helper")
        self.assertEqual(helper["version"], "1.0.0")
        plugin = next(package for package in lock["package"] if package["name"].startswith("hermes-plugin-"))
        self.assertEqual(
            {dependency["name"] for dependency in plugin["dev-dependencies"]["test"]},
            {"hermes-agent", "fixture-helper"},
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)

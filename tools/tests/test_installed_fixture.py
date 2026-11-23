"""Keep the independently installed Rust fixture aligned with producer inputs."""

import tomllib
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


class InstalledRustFixtureTests(unittest.TestCase):
    def test_public_dependency_sources_match_workspace_pins(self):
        workspace = tomllib.loads((ROOT / "Cargo.toml").read_text())["workspace"]
        template = (ROOT / "fixtures/rust-consumer/Cargo.toml.in").read_text()
        revision = "0" * 40
        fixture = tomllib.loads(template.replace("@SDK_REVISION@", revision))

        self.assertIn("workspace", fixture)
        self.assertEqual(
            fixture["dependencies"],
            {
                "desktop-actions": {
                    "git": workspace["package"]["repository"] + ".git",
                    "rev": revision,
                },
                "window-management": workspace["dependencies"]["window-management"],
            },
        )

"""Config loading: defaults, TOML, tables, env overrides, fail-loud validation."""

from __future__ import annotations

import os
import tempfile
import unittest
from pathlib import Path

from foreman import config as config_mod
from foreman.util import ForemanError


class ConfigLoading(unittest.TestCase):
    def load_toml(self, text: str):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / config_mod.CONFIG_FILE).write_text(text, encoding="utf-8")
            return config_mod.load(root)

    def test_defaults_without_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            cfg = config_mod.load(Path(tmp))
        self.assertEqual(cfg.verify_command, ["task", "ci"])
        self.assertTrue(cfg.require_approval)
        self.assertEqual(cfg.billing, "subscription")
        self.assertEqual(cfg.max_parallel, 3)

    def test_toml_values_and_tables(self):
        cfg = self.load_toml(
            'backend = "mock"\n'
            'verify_command = ["task", "verify"]\n'
            "[budgets]\ndispatch_usd = 5.0\n"
            "[timeouts]\nshepherd_min = 10\n"
        )
        self.assertEqual(cfg.backend, "mock")
        self.assertEqual(cfg.verify_command, ["task", "verify"])
        self.assertEqual(cfg.dispatch_budget_usd, 5.0)
        self.assertEqual(cfg.shepherd_timeout_min, 10)

    def test_env_override_wins(self):
        os.environ["FOREMAN_BACKEND"] = "mock"
        try:
            cfg = self.load_toml('backend = "claude"\n')
        finally:
            del os.environ["FOREMAN_BACKEND"]
        self.assertEqual(cfg.backend, "mock")

    def test_invalid_inputs_mode_fails(self):
        with self.assertRaises(ForemanError):
            self.load_toml('inputs = "psychic"\n')

    def test_empty_verify_command_fails(self):
        with self.assertRaises(ForemanError):
            self.load_toml("verify_command = []\n")

    def test_multi_segment_branch_prefix_fails(self):
        with self.assertRaises(ForemanError):
            self.load_toml('branch_prefix = "bots/foreman"\n')

    def test_permission_mode_derivation(self):
        self.assertEqual(
            self.load_toml("sandboxed = true\n").resolved_permission_mode(),
            "bypassPermissions",
        )
        self.assertEqual(self.load_toml("").resolved_permission_mode(), "acceptEdits")


if __name__ == "__main__":
    unittest.main()

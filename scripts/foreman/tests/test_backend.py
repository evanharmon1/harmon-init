"""Backend path containment and least-privilege subprocess environment."""

from __future__ import annotations

import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from foreman import backend
from foreman.config import Config
from foreman.util import ForemanError


class AdapterPathContainment(unittest.TestCase):
    def test_only_direct_backend_files_are_allowed(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "backends"
            root.mkdir()
            direct = root / "mock.sh"
            direct.write_text("#!/bin/sh\n", encoding="utf-8")
            outside = Path(tmp) / "outside.sh"
            outside.write_text("#!/bin/sh\n", encoding="utf-8")
            (root / "linked.sh").symlink_to(outside)
            with patch.object(backend, "BACKENDS_DIR", root):
                self.assertEqual(backend.adapter_path("mock"), direct.resolve())
                for name in ("../outside", "linked", "/tmp/evil", "bad/name", ""):
                    with self.subTest(name=name), self.assertRaises(ForemanError):
                        backend.adapter_path(name)


class BackendEnvironment(unittest.TestCase):
    def test_subscription_environment_excludes_unrelated_credentials(self):
        parent = {
            "PATH": "/bin",
            "HOME": "/tmp/home",
            "LC_ALL": "C",
            "CLAUDE_CODE_OAUTH_TOKEN": "oauth",
            "GH_TOKEN": "scoped-github-token",
            "OP_SESSION_personal": "one-password",
            "AWS_SECRET_ACCESS_KEY": "cloud-secret",
            "CLOUDFLARE_API_TOKEN": "cloudflare-secret",
            "SSH_AUTH_SOCK": "/tmp/agent.sock",
            "ANTHROPIC_API_KEY": "forbidden-override",
            "FOREMAN_READONLY": "1",
        }
        with patch.dict(os.environ, parent, clear=True):
            env = backend.backend_environment(Config(billing="subscription"))
            privileged = backend.backend_environment(
                Config(billing="subscription"), allow_github=True
            )
        self.assertEqual(env["CLAUDE_CODE_OAUTH_TOKEN"], "oauth")
        self.assertEqual(env["LC_ALL"], "C")
        self.assertEqual(env["FOREMAN_READONLY"], "1")
        self.assertNotIn("GH_TOKEN", env)
        self.assertEqual(privileged["GH_TOKEN"], "scoped-github-token")
        for key in (
            "OP_SESSION_personal",
            "AWS_SECRET_ACCESS_KEY",
            "CLOUDFLARE_API_TOKEN",
            "SSH_AUTH_SOCK",
            "ANTHROPIC_API_KEY",
        ):
            self.assertNotIn(key, env)
            self.assertNotIn(key, privileged)

    def test_api_billing_passes_only_the_foreman_api_key(self):
        parent = {
            "PATH": "/bin",
            "CLAUDE_CODE_OAUTH_TOKEN": "oauth",
            "FOREMAN_ANTHROPIC_API_KEY": "api-key",
        }
        with patch.dict(os.environ, parent, clear=True):
            env = backend.backend_environment(Config(billing="api"))
        self.assertEqual(env["FOREMAN_ANTHROPIC_API_KEY"], "api-key")
        self.assertNotIn("CLAUDE_CODE_OAUTH_TOKEN", env)

    def test_api_billing_requires_the_foreman_api_key(self):
        with patch.dict(os.environ, {"PATH": "/bin"}, clear=True):
            with self.assertRaises(ForemanError):
                backend.backend_environment(Config(billing="api"))


if __name__ == "__main__":
    unittest.main()

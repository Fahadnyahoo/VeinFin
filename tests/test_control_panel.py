#!/usr/bin/env python3
"""Offline security and lifecycle tests for the Control panel setup panel."""

import base64
import hashlib
import importlib.util
import os
import pathlib
import time
import unittest
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("panel", ROOT / "panel/app.py")
PANEL = importlib.util.module_from_spec(SPEC); SPEC.loader.exec_module(PANEL)


class PanelTests(unittest.TestCase):
    def test_password_hash_accepts_only_exact_password(self):
        salt = bytes(range(16)); password = "correct horse"
        value = hashlib.pbkdf2_hmac("sha256", password.encode(), salt, 600000, dklen=32)
        encoded = "pbkdf2-sha256$600000$%s$%s" % (
            base64.urlsafe_b64encode(salt).decode(), base64.urlsafe_b64encode(value).decode())
        self.assertTrue(PANEL.verify_password(password, encoded))
        self.assertFalse(PANEL.verify_password("wrong", encoded))
        self.assertFalse(PANEL.verify_password(password, "malformed"))

    def test_exact_inventory_excludes_panel_agent_and_experimental_plugin(self):
        self.assertEqual(set(PANEL.SERVICES), {"reverse-proxy", "jellyfin", "qbittorrent", "sonarr", "radarr",
            "prowlarr", "bazarr", "seerr", "flaresolverr", "recyclarr"})
        self.assertNotIn("veinfin-panel", PANEL.SERVICES)
        self.assertNotIn("veinfin-agent", PANEL.SERVICES)

    def test_container_name_rejects_injection_and_unknown_names(self):
        with mock.patch.dict(os.environ, {"COMPOSE_PROJECT_NAME": "veinfin"}):
            self.assertEqual(PANEL.container_name("sonarr"), "/veinfin-sonarr-1")
            for value in ("../sonarr", "sonarr?x=1", "veinfin-panel", "unknown", "sonarr/restart"):
                with self.assertRaises(ValueError): PANEL.container_name(value)

    def test_recyclarr_absence_is_on_demand_not_fake_running(self):
        with mock.patch.object(PANEL, "docker", side_effect=RuntimeError("Docker operation failed with status 404")):
            item = PANEL.inspect_service("recyclarr")
        self.assertFalse(item["running"]); self.assertEqual(item["state"], "on-demand")

    def test_html_uses_text_content_and_no_credential_visit_construction(self):
        self.assertIn("textContent", PANEL.HTML)
        self.assertNotIn("innerHTML", PANEL.HTML)
        self.assertNotIn("password=", PANEL.HTML)
        self.assertNotIn("token=", PANEL.HTML)

    def test_expired_session_is_removed(self):
        handler = object.__new__(PANEL.PanelHandler)
        handler.server = type("Server", (), {"session_secret": "secret"})()
        signature = __import__("hmac").new(b"secret", b"expired", hashlib.sha256).hexdigest()
        handler.headers = {"Cookie": "__Host-veinfin=expired." + signature}
        PANEL.PanelHandler.sessions = {"expired": {"csrf": "value", "expires": time.time() - 1}}
        self.assertIsNone(handler.session())
        self.assertNotIn("expired", PANEL.PanelHandler.sessions)


if __name__ == "__main__":
    unittest.main()

#!/usr/bin/env python3
"""Deterministic offline tests for the Quality profile setup quality policy."""

import importlib.util
import json
import os
import pathlib
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("quality_profiles", ROOT / "scripts/deploy/quality_profiles.py")
QUALITY_PROFILES = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(QUALITY_PROFILES)
POLICY_PATH = ROOT / "config/quality-policy.json"


class QualityProfilePolicyTests(unittest.TestCase):
    def setUp(self):
        self.policy = QUALITY_PROFILES.validate_policy(json.loads(POLICY_PATH.read_text()))

    def qualities(self, key):
        return {quality for item in self.policy["profiles"][key]["qualities"]
                for quality in item.get("qualities", [item["name"]])}

    def test_movie_4k_has_1080p_fallback_without_remux(self):
        values = self.qualities("movies")
        self.assertTrue(any("2160" in value for value in values))
        self.assertTrue(any("1080" in value for value in values))
        self.assertFalse(any("Remux" in value for value in values))

    def test_tv_and_anime_are_1080p_sdr_only(self):
        for key in ("tv", "anime"):
            values = self.qualities(key)
            self.assertTrue(values)
            self.assertTrue(all("1080" in value for value in values))
            self.assertFalse(any("2160" in value or "Remux" in value for value in values))
            rejected = " ".join(self.policy["profiles"][key]["reject"])
            self.assertIn("HDR family", rejected)
            self.assertIn("AV1", rejected)

    def test_tv_and_anime_size_limits_are_verified_without_global_mutation(self):
        source = (ROOT / "scripts/deploy/quality_profiles.py").read_text()
        self.assertIn("finite maximum size for every allowed quality", source)
        self.assertIn('"quality_definitions"', source)
        self.assertNotIn("quality_definition:", (ROOT / "config/quality-policy.json").read_text())

    def test_movie_dolby_vision_requires_hdr_fallback(self):
        rejected = self.policy["profiles"]["movies"]["reject"]
        self.assertIn("Dolby Vision without HDR10 fallback", rejected)
        self.assertNotIn("HDR", rejected)

    def test_every_profile_rejects_av1_low_quality_and_upscales(self):
        for profile in self.policy["profiles"].values():
            text = " ".join(profile["reject"])
            self.assertIn("AV1", text)
            self.assertIn("Low-quality", text)
            self.assertIn("Upscaled", text)

    def test_anime_audio_preferences_do_not_filter_subtitle_tracks(self):
        anime = self.policy["profiles"]["anime"]
        self.assertIn("Dubs only", anime["reject"])
        self.assertIn("Anime dual audio", anime["prefer"])
        self.assertFalse(any("subtitle" in name.lower() for name in anime["reject"]))

    def test_generated_configuration_is_secret_and_deterministic(self):
        profiles = list(self.policy["profiles"].values())
        first = QUALITY_PROFILES.render_instance("sonarr", [x for x in profiles if x["application"] == "sonarr"], "secret-value")
        second = QUALITY_PROFILES.render_instance("sonarr", [x for x in profiles if x["application"] == "sonarr"], "secret-value")
        self.assertEqual(first, second)
        text = "\n".join(first)
        self.assertIn("VeinFin TV 1080p SDR", text)
        self.assertIn("VeinFin Anime 1080p SDR", text)
        self.assertNotIn("Remux", text)

    def test_preview_gate_rejects_out_of_scope_drift_and_secrets(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            secret_s, secret_r = root / "s", root / "r"
            for path, value in ((secret_s, "s" * 32), (secret_r, "r" * 32)):
                path.write_text(value); os.chmod(path, 0o600)
            config = root / "config.yml"; config.write_text("safe\n"); os.chmod(config, 0o600)
            class Args: pass
            args = Args(); args.policy = str(POLICY_PATH); args.config = str(config)
            args.sonarr_key_file = str(secret_s); args.radarr_key_file = str(secret_r)
            args.output = str(root / "summary.json")
            for content in ("delete unrelated quality profile", "start media search", "s" * 32):
                preview = root / "preview.log"; preview.write_text(content); args.preview = str(preview)
                with self.assertRaises(RuntimeError): QUALITY_PROFILES.preview_summary(args)

    def test_preview_summary_is_sanitized_and_structured(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            for name in ("s", "r"):
                path = root / name; path.write_text(name * 32); os.chmod(path, 0o600)
            config = root / "config.yml"; config.write_text("safe\n")
            preview = root / "preview.log"; preview.write_text(
                "[INF] Processing Sonarr server veinfin-sonarr\n"
                "[INF] Processing Radarr server veinfin-radarr\n"
                "No quality_definition configured, skipping quality sizes\n"
                "VeinFin Movies 4K VeinFin TV 1080p SDR VeinFin Anime 1080p SDR")
            class Args: pass
            args = Args(); args.policy = str(POLICY_PATH); args.config = str(config)
            args.preview = str(preview); args.output = str(root / "summary.json")
            args.sonarr_key_file = str(root / "s"); args.radarr_key_file = str(root / "r")
            QUALITY_PROFILES.preview_summary(args)
            summary = json.loads(pathlib.Path(args.output).read_text())
            self.assertEqual(len(summary["profiles"]), 3)
            self.assertEqual(summary["safety"], {"searches": False, "downloads": False,
                "assignments": False, "naming_changes": False, "media_management_changes": False})
            self.assertNotIn("Processing Sonarr", json.dumps(summary))


if __name__ == "__main__":
    unittest.main()

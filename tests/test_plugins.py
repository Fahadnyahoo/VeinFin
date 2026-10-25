import hashlib
import importlib.util
import json
import os
import pathlib
import tempfile
import unittest
import zipfile
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("plugins", ROOT / "scripts/deploy/plugins.py")
plugins = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(plugins)


class PluginLockTests(unittest.TestCase):
    def test_repository_lock_is_valid_and_excludes_deferred_plugin(self):
        entries = plugins.parse_lock(ROOT / "config/plugins.lock")
        self.assertEqual({e["key"] for e in entries}, {
            "JELLYFIN_ENHANCED", "MEDIA_BAR_ENHANCED", "HOME_SCREEN_SECTIONS",
            "CUSTOM_TABS", "JAVASCRIPT_INJECTOR", "FILE_TRANSFORMATION",
            "HOVER_TRAILER", "INPLAYER_EPISODE_PREVIEW", "INTRO_SKIPPER",
            "LOCAL_POSTERS", "ANILIST", "ANISEARCH",
        })
        self.assertFalse(any("watching" in e["name"].lower() for e in entries))

    def test_rejects_arbitrary_url_and_duplicate_guid(self):
        line = ("TEST|Test|00000000-0000-4000-8000-000000000001|1.0.0.0|12.0.0.0|MIT|"
                "https://github.com/example/test|https://example.invalid/test.zip|" + "a" * 64 + "|true|Test.dll=" + "b" * 64)
        with tempfile.TemporaryDirectory() as directory:
            lock = pathlib.Path(directory) / "lock"
            lock.write_text(line + "\n", encoding="utf-8")
            with self.assertRaisesRegex(RuntimeError, "non-allowlisted"):
                plugins.parse_lock(lock)

    def test_rejects_who_is_watching(self):
        line = ("TEST|Whos Watching|00000000-0000-4000-8000-000000000001|1.0.0.0|12.0.0.0|MIT|"
                "https://github.com/example/test|https://github.com/example/test/releases/download/v1/test.zip|" +
                "a" * 64 + "|true|Test.dll=" + "b" * 64)
        with tempfile.TemporaryDirectory() as directory:
            lock = pathlib.Path(directory) / "lock"
            lock.write_text(line + "\n", encoding="utf-8")
            with self.assertRaisesRegex(RuntimeError, "forbidden"):
                plugins.parse_lock(lock)

    def test_archive_is_exact_atomic_and_restrictive(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            archive = root / "plugin.zip"
            payload = b"reviewed plugin"
            with zipfile.ZipFile(archive, "w") as bundle:
                bundle.writestr("Plugin.dll", payload)
            entry = {"name": "Test", "artifact_sha256": plugins.sha256(archive),
                     "files": {"Plugin.dll": hashlib.sha256(payload).hexdigest()}}
            output = root / "ready"
            plugins.verify_archive(entry, archive, output)
            self.assertEqual((output / "Plugin.dll").read_bytes(), payload)
            self.assertEqual(os.stat(output).st_mode & 0o777, 0o700)
            self.assertEqual(os.stat(output / "Plugin.dll").st_mode & 0o777, 0o600)
            leftovers = list(root.glob(".ready.*"))
            self.assertEqual(leftovers, [])

    def test_archive_rejects_traversal(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            archive = root / "bad.zip"
            with zipfile.ZipFile(archive, "w") as bundle:
                bundle.writestr("../Plugin.dll", b"bad")
            entry = {"name": "Test", "artifact_sha256": plugins.sha256(archive),
                     "files": {"Plugin.dll": hashlib.sha256(b"bad").hexdigest()}}
            with self.assertRaisesRegex(RuntimeError, "unsafe archive"):
                plugins.verify_archive(entry, archive, root / "ready")

    def test_existing_stage_is_verification_only(self):
        entry = {"key": "TEST", "name": "Test", "version": "1.0.0.0",
                 "artifact_url": "https://github.com/example/test/releases/download/v1/test.zip",
                 "artifact_sha256": "0" * 64,
                 "files": {"Plugin.dll": hashlib.sha256(b"same").hexdigest()}}
        with tempfile.TemporaryDirectory() as directory:
            output = pathlib.Path(directory) / "out"
            target = output / "TEST-1.0.0.0"
            target.mkdir(parents=True)
            (target / "Plugin.dll").write_bytes(b"same")
            plugins.stage([entry], output)
            self.assertEqual((target / "Plugin.dll").read_bytes(), b"same")

    def test_live_guid_comparison_accepts_jellyfin_compact_format(self):
        entry = {"name": "Test", "guid": "00000000-0000-4000-8000-000000000001", "version": "1.0.0.0"}
        state = {"version": "12.3.0", "users": 1, "libraries": [], "counts": {},
                 "watched": 0, "in_progress": 0,
                 "configuration": plugins.DESIRED_CONFIGURATION,
                 "plugins": [{"id": "00000000000040008000000000000001", "name": "Test",
                              "version": "1.0.0.0", "status": "Active"}]}
        plugins.verify_live([entry], state)

    def test_atomic_json_never_changes_existing_parent_permissions(self):
        with tempfile.TemporaryDirectory() as directory:
            parent = pathlib.Path(directory) / "shared"
            parent.mkdir(mode=0o755)
            before = os.stat(parent).st_mode & 0o777
            plugins.atomic_json(parent / "state.json", {"safe": True})
            self.assertEqual(os.stat(parent).st_mode & 0o777, before)
            self.assertEqual(os.stat(parent / "state.json").st_mode & 0o777, 0o600)

    def test_ui_contract_keeps_external_integrations_and_auto_skip_off(self):
        enhanced = plugins.load_enhanced_profile(ROOT / "config/jellyfin-enhanced-profile.json")["safe_portable_defaults"]
        skipper = plugins.DESIRED_CONFIGURATION["INTRO_SKIPPER"]
        self.assertFalse(enhanced["AnalyticsEnabled"])
        self.assertTrue(enhanced["JellyseerrEnabled"])
        self.assertTrue(enhanced["JellyseerrShowSearchResults"])
        self.assertFalse(skipper["UseFileTransformationPlugin"])
        self.assertNotIn("AutoSkipIntro", skipper)
        self.assertNotIn("AutoSkipCredits", skipper)

    def test_live_profile_classifies_every_setting_without_sensitive_defaults(self):
        profile = plugins.load_enhanced_profile(ROOT / "config/jellyfin-enhanced-profile.json")
        portable = profile["safe_portable_defaults"]
        classified = profile["classification"]
        all_keys = set(portable)
        for values in classified.values():
            self.assertFalse(all_keys.intersection(values))
            all_keys.update(values)
        self.assertEqual(len(all_keys), 357)
        self.assertEqual(len(portable), 304)
        self.assertIn("JellyseerrApiKey", classified["secret"])
        self.assertIn("SonarrInstances", classified["installation_specific"])
        self.assertIn("MaintenanceModeAffectedUsers", classified["user_specific_state"])
        serialized = json.dumps(portable, sort_keys=True)
        self.assertNotRegex(serialized, r"https?://")
        self.assertNotRegex(serialized, r"(?<![0-9])(?:10|127|169\.254|172\.(?:1[6-9]|2[0-9]|3[01])|192\.168)(?:\.\d{1,3}){2}(?![0-9])")
        self.assertNotRegex(serialized, r'"/(?:[^"\\]|\\.)+"')
        self.assertNotRegex(serialized, r"\b(?:[a-z0-9-]+\.)+(?:com|net|org|local|lan|internal|test)\b")

    def test_integration_configuration_uses_runtime_values_and_empty_mappings(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            sonarr = root / "sonarr-api-key"
            radarr = root / "radarr-api-key"
            seerr = root / "seerr-api-key"
            tmdb = root / "tmdb-api-key"
            sonarr.write_text("sonarr-secret\n", encoding="utf-8")
            radarr.write_text("radarr-secret\n", encoding="utf-8")
            seerr.write_text("seerr-secret\n", encoding="utf-8")
            os.chmod(sonarr, 0o600)
            os.chmod(radarr, 0o600)
            os.chmod(seerr, 0o600)
            profile, desired = plugins.integration_configuration(
                ROOT / "config/jellyfin-enhanced-profile.json", sonarr, radarr, seerr, tmdb)
            self.assertEqual(profile["plugin_version"], "12.13.0.0")
            self.assertEqual(json.loads(desired["SonarrInstances"])[0]["Name"], "TV & Anime")
            self.assertEqual(json.loads(desired["RadarrInstances"])[0]["Name"], "Movies")
            self.assertEqual(desired["BazarrUrl"], "http://bazarr:6767")
            self.assertNotIn("BazarrApiKey", desired)
            self.assertEqual(desired["SonarrUrlMappings"], "")
            self.assertEqual(desired["RadarrUrlMappings"], "")
            self.assertEqual(desired["BazarrUrlMappings"], "")
            self.assertTrue(desired["JellyseerrEnabled"])
            self.assertTrue(desired["JellyseerrShowSearchResults"])
            self.assertEqual(desired["JellyseerrUrls"], "http://seerr:5055")
            self.assertEqual(desired["JellyseerrUrlMappings"], "")
            self.assertEqual(desired["TMDB_API_KEY"], "")
            self.assertNotIn("MaintenanceModeAffectedUsers", desired)
            self.assertNotIn("AnalyticsInstallSecret", desired)

    def test_connection_checks_send_keys_only_as_headers(self):
        desired = {"SonarrUrl": "http://sonarr:8989", "SonarrApiKey": "sonarr-secret",
                   "RadarrUrl": "http://radarr:7878", "RadarrApiKey": "radarr-secret"}
        with mock.patch.object(plugins, "request", return_value={"ok": True}) as request:
            plugins.validate_arr_connections("token", desired, "http://jellyfin")
        self.assertEqual(request.call_count, 2)
        for call in request.call_args_list:
            self.assertNotIn("secret", call.args[1])
            self.assertIn("X-Arr-ApiKey", call.kwargs["extra_headers"])

    def test_seerr_search_requires_unavailable_movie_and_show(self):
        response = {"results": [
            {"mediaType": "movie", "mediaInfo": None},
            {"mediaType": "tv", "mediaInfo": None},
        ]}
        with mock.patch.object(plugins, "request", return_value=response):
            plugins.verify_seerr_search("token", "http://jellyfin")

    def test_seerr_search_rejects_available_only_results(self):
        response = {"results": [
            {"mediaType": "movie", "mediaInfo": {"status": 5}},
            {"mediaType": "tv", "mediaInfo": {"status": 5}},
        ]}
        with mock.patch.object(plugins, "request", return_value=response):
            with self.assertRaisesRegex(RuntimeError, "unavailable movie and show"):
                plugins.verify_seerr_search("token", "http://jellyfin")

    def test_integration_rollback_uses_supported_api_and_exact_backup(self):
        profile = plugins.load_enhanced_profile(ROOT / "config/jellyfin-enhanced-profile.json")
        previous = dict(profile["safe_portable_defaults"])
        current = dict(previous)
        for category in plugins.PROFILE_CATEGORIES:
            for key in profile["classification"][category]:
                previous[key] = "previous"
                current[key] = "current"
        with tempfile.TemporaryDirectory() as directory:
            backup = pathlib.Path(directory) / "backup.json"
            plugins.atomic_json(backup, previous)
            entries = [{"key": "JELLYFIN_ENHANCED", "guid": plugins.ENHANCED_GUID}]
            with mock.patch.object(plugins, "login", return_value=("token", {})), \
                    mock.patch.object(plugins, "request", side_effect=[current, None, previous, None]) as call:
                plugins.restore_integrations(entries, "admin", "password-file", profile, backup)
        writes = [entry for entry in call.call_args_list if entry.args[0] == "POST" and "/Plugins/" in entry.args[1]]
        self.assertEqual(len(writes), 1)
        self.assertEqual(writes[0].args[3], previous)


if __name__ == "__main__":
    unittest.main()

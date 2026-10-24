#!/usr/bin/env python3
"""Deterministic offline tests for the Indexer and subtitle setup API helper."""

import importlib.util
import pathlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("indexers_subtitles", ROOT / "scripts/deploy/indexers_subtitles.py")
INDEXERS_SUBTITLES = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(INDEXERS_SUBTITLES)


class FakeProwlarr:
    def __init__(self, fail=False):
        self.fail = fail
        self.calls = []

    def call(self, method, path, body=None, timeout=30):
        self.calls.append((method, path, body, timeout))
        if self.fail:
            raise RuntimeError("connection test failed")
        return None


def schema(name="Nyaa.si", privacy="public", fields=None, categories=None):
    return {"name": name, "privacy": privacy, "fields": fields or [],
            "capabilities": {"categories": categories or []}}


class IndexerSubtitleTests(unittest.TestCase):
    def test_no_credential_enforcement(self):
        self.assertTrue(INDEXERS_SUBTITLES.credential_free(schema()))
        self.assertFalse(INDEXERS_SUBTITLES.credential_free(schema(privacy="private")))
        self.assertFalse(INDEXERS_SUBTITLES.credential_free(schema(fields=[{"name": "apiKey", "required": True}])))

    def test_category_discovery_is_recursive(self):
        value = schema(categories=[{"id": 5000, "name": "TV", "subCategories": [
            {"id": 5070, "name": "TV/Anime"}]}, {"id": 2000, "name": "Movies"}])
        self.assertEqual(INDEXERS_SUBTITLES.categories(value), {5000: "TV", 5070: "TV/Anime", 2000: "Movies"})

    def test_flaresolverr_is_scoped_only_when_schema_indicates_it(self):
        plain = FakeProwlarr()
        passed, _, uses_proxy = INDEXERS_SUBTITLES.test_candidate(plain, schema(), 1, 9)
        self.assertTrue(passed)
        self.assertFalse(uses_proxy)
        self.assertEqual(plain.calls[0][2]["tags"], [])
        protected = FakeProwlarr()
        value = schema(fields=[{"name": "info_flaresolverr", "required": False}])
        passed, _, uses_proxy = INDEXERS_SUBTITLES.test_candidate(protected, value, 1, 9)
        self.assertTrue(passed)
        self.assertTrue(uses_proxy)
        self.assertEqual(protected.calls[0][2]["tags"], [9])

    def test_failed_connection_is_not_enabled(self):
        passed, result, _ = INDEXERS_SUBTITLES.test_candidate(FakeProwlarr(fail=True), schema(), 1, 9)
        self.assertFalse(passed)
        self.assertEqual(result, "connection-test-failed")

    def test_profiles_are_exact_and_safe(self):
        profiles = INDEXERS_SUBTITLES.profiles_payload()
        self.assertEqual([item["name"] for item in profiles], ["Movies", "TV", "Anime"])
        for profile in profiles:
            self.assertEqual([item["language"] for item in profile["items"]], ["ar", "en"])
            self.assertIsNone(profile["cutoff"])
            self.assertFalse(profile["originalFormat"])
            for item in profile["items"]:
                self.assertEqual(item["hi"], "False")
                self.assertEqual(item["forced"], "False")

    def test_provider_set_is_bounded_and_credential_free(self):
        self.assertEqual(INDEXERS_SUBTITLES.BAZARR_PROVIDERS, ("embeddedsubtitles", "subtitlecat"))
        self.assertLessEqual(len(INDEXERS_SUBTITLES.BAZARR_PROVIDERS), 2)


if __name__ == "__main__":
    unittest.main()

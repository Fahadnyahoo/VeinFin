#!/usr/bin/env python3
"""API-only Indexer and subtitle setup indexer and subtitle-provider foundation."""

import argparse
import http.cookiejar
import json
import os
import pathlib
import re
import secrets
import shutil
import socket
import sqlite3
import sys
import time
import urllib.error
import urllib.parse
import urllib.request


ARR = {"sonarr": (8989, "v3"), "radarr": (7878, "v3"), "prowlarr": (9696, "v1")}
INDEXER_CANDIDATES = (
    ("Nyaa.si", "nyaasi"),
    ("1337x", "1337x"),
    ("TorrentGalaxy", "torrentgalaxy"),
)
BAZARR_PROVIDERS = ("embeddedsubtitles", "subtitlecat")
PROFILE_NAMES = ("Movies", "TV", "Anime")


def fail(message):
    raise RuntimeError(message)


def file_mode(path):
    return pathlib.Path(path).stat().st_mode & 0o777


def read_secret(path):
    path = pathlib.Path(path)
    if not path.is_file() or path.is_symlink() or file_mode(path) != 0o600:
        fail(f"unsafe secret file: {path.name}")
    value = path.read_text(encoding="utf-8").rstrip("\r\n")
    if not value:
        fail(f"empty secret file: {path.name}")
    return value


def atomic_bytes(path, data):
    path = pathlib.Path(path)
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(path.parent, 0o700)
    temporary = path.parent / f".{path.name}.{secrets.token_hex(8)}"
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.chown(temporary, 0, 0)
        os.replace(temporary, path)
    finally:
        if temporary.exists():
            temporary.unlink()


def atomic_json(path, value):
    atomic_bytes(path, (json.dumps(value, indent=2, sort_keys=True) + "\n").encode())


def protected_json(path):
    path = pathlib.Path(path)
    if not path.is_file() or path.is_symlink() or file_mode(path) != 0o600:
        fail(f"protected state is missing or unsafe: {path.name}")
    return json.loads(path.read_text(encoding="utf-8"))


def redact(text):
    text = re.sub(r"https?://[^\s\"<>]+", "[url]", str(text))
    return re.sub(r"[A-Za-z0-9+/_=-]{24,}", "[redacted]", text)[:500]


class Api:
    def __init__(self, name, key):
        self.name = name
        port, version = ARR[name]
        self.base = f"http://127.0.0.1:{port}/api/{version}/"
        self.headers = {"X-Api-Key": key}

    def call(self, method, path, body=None, timeout=30, allowed=(200, 201, 202, 204)):
        headers = dict(self.headers)
        data = None
        if body is not None:
            data = json.dumps(body, separators=(",", ":")).encode()
            headers["Content-Type"] = "application/json"
        request = urllib.request.Request(self.base + path, data=data, method=method, headers=headers)
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                raw = response.read()
                if response.status not in allowed:
                    fail(f"{self.name} rejected {path} (HTTP {response.status})")
                return json.loads(raw) if raw else None
        except urllib.error.HTTPError as error:
            detail = redact(error.read().decode(errors="replace"))
            fail(f"{self.name} rejected {path} (HTTP {error.code})" + (f": {detail}" if detail else ""))

    def get(self, path):
        return self.call("GET", path)


class Bazarr:
    def __init__(self, key):
        self.base = "http://127.0.0.1:6767/api/"
        self.headers = {"X-API-KEY": key}

    def call(self, method, path, body=None, form=False):
        headers = dict(self.headers)
        if body is None:
            data = None
        elif form:
            data = urllib.parse.urlencode(body, doseq=True).encode()
            headers["Content-Type"] = "application/x-www-form-urlencoded"
        else:
            data = json.dumps(body, separators=(",", ":")).encode()
            headers["Content-Type"] = "application/json"
        request = urllib.request.Request(self.base + path, data=data, method=method, headers=headers)
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                raw = response.read()
                return json.loads(raw) if raw else None
        except urllib.error.HTTPError as error:
            fail(f"Bazarr rejected {path} (HTTP {error.code})")

    def get(self, path):
        return self.call("GET", path)


def field_values(resource):
    return {item.get("name"): item.get("value") for item in resource.get("fields", [])}


def set_fields(resource, values):
    fields = {item.get("name"): item for item in resource.get("fields", [])}
    missing = set(values) - set(fields)
    if missing:
        fail("live API schema omitted required fields")
    for name, value in values.items():
        fields[name]["value"] = value


def app_clients(args):
    return {
        name: Api(name, read_secret(getattr(args, f"{name}_key_file")))
        for name in ARR
    }


def qbit_count(username, password):
    jar = http.cookiejar.CookieJar()
    opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))
    data = urllib.parse.urlencode({"username": username, "password": password}).encode()
    opener.open(urllib.request.Request("http://127.0.0.1:8080/api/v2/auth/login", data=data), timeout=15).read()
    return len(json.load(opener.open("http://127.0.0.1:8080/api/v2/torrents/info", timeout=15)))


def categories(resource):
    result = {}
    def walk(values):
        for item in values:
            result[int(item["id"])] = item.get("name", "")
            walk(item.get("subCategories") or [])
    walk((resource.get("capabilities") or {}).get("categories") or [])
    return result


def credential_free(resource):
    if resource.get("privacy") != "public":
        return False
    forbidden = re.compile(r"user|pass|api.?key|token|cookie|captcha|credential", re.I)
    for field in resource.get("fields", []):
        if forbidden.search(str(field.get("name", ""))) and field.get("required"):
            return False
    return True


def candidate_schemas(prowlarr):
    schemas = prowlarr.get("indexer/schema")
    result = {}
    for label, definition in INDEXER_CANDIDATES:
        matches = [item for item in schemas if item.get("definitionName") == definition]
        if len(matches) > 1:
            fail(f"Prowlarr candidate {label} is ambiguous")
        result[label] = matches[0] if matches else None
    return result


def proxy_tag(prowlarr):
    proxies = [item for item in prowlarr.get("indexerProxy") if item.get("implementation") == "FlareSolverr"]
    if len(proxies) != 1:
        fail("dedicated FlareSolverr proxy is missing or ambiguous")
    tags = {item["id"]: item.get("label") for item in prowlarr.get("tag")}
    values = proxies[0].get("tags") or []
    if len(values) != 1 or tags.get(values[0]) != "flaresolverr":
        fail("FlareSolverr proxy tag is not exact")
    return values[0]


def test_candidate(prowlarr, resource, profile_id, flaresolverr_tag):
    if not credential_free(resource):
        return False, "credentials-required", False
    needs_flaresolverr = any(item.get("name") == "info_flaresolverr" for item in resource.get("fields", []))
    candidate = json.loads(json.dumps(resource))
    candidate.update(name=resource["name"], enable=True, redirect=False, priority=25,
                     downloadClientId=0, appProfileId=profile_id,
                     tags=[flaresolverr_tag] if needs_flaresolverr else [])
    try:
        prowlarr.call("POST", "indexer/test", candidate, timeout=20)
        return True, "connection-test-passed", needs_flaresolverr
    except (RuntimeError, TimeoutError, socket.timeout):
        return False, "connection-test-failed", needs_flaresolverr


def test_applications(apps, keys):
    prowlarr = apps["prowlarr"]
    schemas = prowlarr.get("applications/schema")
    current = prowlarr.get("applications")
    expected = {"Sonarr": "http://sonarr:8989", "Radarr": "http://radarr:7878"}
    if {item.get("implementation") for item in current} != set(expected):
        fail("Prowlarr application set changed")
    for implementation, base_url in expected.items():
        live = next(item for item in current if item.get("implementation") == implementation)
        schema = [item for item in schemas if item.get("implementation") == implementation]
        if len(schema) != 1 or not live.get("enable") or live.get("syncLevel") != "fullSync":
            fail("Prowlarr application synchronization contract changed")
        resource = schema[0]
        resource.update(id=live["id"], name=live["name"], enable=True, syncLevel="fullSync", tags=live.get("tags", []))
        set_fields(resource, {"prowlarrUrl": "http://prowlarr:9696", "baseUrl": base_url,
                              "apiKey": keys[implementation.lower()], "authUsername": "", "authPassword": ""})
        prowlarr.call("POST", "applications/test", resource)


def wait_command(app, command_id):
    deadline = time.monotonic() + 180
    while time.monotonic() < deadline:
        command = app.get(f"command/{command_id}")
        status = str(command.get("status", "")).lower()
        if status == "completed":
            return
        if status in ("failed", "aborted"):
            fail("Prowlarr application synchronization failed")
        time.sleep(2)
    fail("Prowlarr application synchronization timed out")


def profiles_payload():
    profiles = []
    for profile_id, name in enumerate(PROFILE_NAMES, 1):
        profiles.append({
            "profileId": profile_id, "name": name, "cutoff": None,
            "items": [
                {"id": 1, "language": "ar", "audio_exclude": "False", "audio_only_include": "False", "hi": "False", "forced": "False"},
                {"id": 2, "language": "en", "audio_exclude": "False", "audio_only_include": "False", "hi": "False", "forced": "False"},
            ],
            "mustContain": [], "mustNotContain": [], "originalFormat": False, "tag": None,
        })
    return profiles


def bazarr_zero_activity(bazarr):
    for endpoint in ("episodes/wanted", "movies/wanted", "episodes/history", "movies/history"):
        result = bazarr.get(endpoint + "?start=0&length=1")
        if int(result.get("total", -1)) != 0:
            fail("Bazarr wanted/history state is not empty")


def current_state(args):
    apps = app_clients(args)
    bazarr = Bazarr(read_secret(args.bazarr_key_file))
    for app in apps.values():
        app.get("system/status")
    settings = bazarr.get("system/settings")
    languages = bazarr.get("system/languages")
    profiles = bazarr.get("system/languages/profiles")
    series = bazarr.get("series?start=0&length=100").get("data", [])
    return apps, bazarr, settings, languages, profiles, series


def verify_preserved_content(args, apps, bazarr):
    sonarr, radarr = apps["sonarr"], apps["radarr"]
    series = sonarr.get("series")
    if len(series) != 1 or len(sonarr.get(f"episodefile?seriesId={series[0]['id']}")) != 170:
        fail("Sonarr series or episode-file state changed")
    if radarr.get("movie"):
        fail("Radarr is no longer empty")
    if qbit_count(args.username, read_secret(args.password_file)) != 0:
        fail("qBittorrent contains a torrent")
    for name in ("sonarr", "radarr", "prowlarr"):
        commands = apps[name].get("command")
        active = [item for item in commands
                  if re.search(r"search|rss|grab|download", str(item.get("name", "")), re.I)
                  and str(item.get("status", "")).lower() not in ("completed", "failed", "aborted")]
        if active:
            fail(f"{name} has an active search or download command")
    bazarr_zero_activity(bazarr)


def check_mode(args, expected):
    apps, bazarr, settings, languages, profiles, bazarr_series = current_state(args)
    keys = {name: read_secret(getattr(args, f"{name}_key_file")) for name in ("sonarr", "radarr")}
    test_applications(apps, keys)
    verify_preserved_content(args, apps, bazarr)
    if len(bazarr_series) != 1:
        fail("Bazarr series synchronization state changed")
    if any(item.get("profileId") is not None for item in bazarr_series):
        fail("Indexer and subtitle setup must not assign a profile or scan existing media")
    if expected == "empty":
        if apps["prowlarr"].get("indexer") or profiles or settings["general"].get("enabled_providers"):
            fail("Indexer and subtitle setup baseline is not empty")
    else:
        report = protected_json(args.report)
        intended = set(report["enabled_indexers"])
        indexers = apps["prowlarr"].get("indexer")
        if {item.get("name") for item in indexers} != intended:
            fail("Prowlarr indexer set is not exact")
        fs_tag = proxy_tag(apps["prowlarr"])
        for item in indexers:
            schema = next((x for x in candidate_schemas(apps["prowlarr"]).values() if x and x.get("definitionName") == field_values(item).get("definitionFile")), None)
            needs = bool(schema and any(x.get("name") == "info_flaresolverr" for x in schema.get("fields", [])))
            if item.get("tags", []) != ([fs_tag] if needs else []):
                fail("FlareSolverr tag scope is incorrect")
            apps["prowlarr"].call("POST", "indexer/test", item, timeout=20)
        expected_profiles = profiles_payload()
        if profiles != expected_profiles:
            fail("Bazarr Arabic/English profiles are not exact")
        enabled_languages = {item["code2"] for item in languages if item.get("enabled")}
        if enabled_languages != {"ar", "en"}:
            fail("Bazarr enabled-language set is not exact")
        if tuple(settings["general"].get("enabled_providers") or []) != BAZARR_PROVIDERS:
            fail("Bazarr provider set is not exact")
        if settings.get("subtitlecat", {}).get("include_machine_translated"):
            fail("machine-translated subtitles are enabled")
        # Prowlarr-synchronized indexers must be present in each compatible Arr app.
        for name in ("sonarr", "radarr"):
            arr_indexers = apps[name].get("indexer")
            if len(arr_indexers) != len(indexers):
                fail(f"{name} synchronized indexer count differs")
            for item in arr_indexers:
                apps[name].call("POST", "indexer/test", item, timeout=30)
    print(f"CHECK={expected.upper()} INDEXERS={len(apps['prowlarr'].get('indexer'))} PROFILES={len(profiles)} PROVIDERS={len(settings['general'].get('enabled_providers') or [])}")


def api_snapshot(args):
    apps, bazarr, settings, languages, profiles, bazarr_series = current_state(args)
    return {
        "prowlarr": {"indexers": apps["prowlarr"].get("indexer")},
        "bazarr": {
            "enabled_languages": [item["code2"] for item in languages if item.get("enabled")],
            "profiles": profiles,
            "providers": settings["general"].get("enabled_providers") or [],
            "series_profiles": [{"seriesid": item["sonarrSeriesId"], "profileid": item.get("profileId")} for item in bazarr_series],
        },
    }


def sqlite_backup(source, destination):
    source_db = sqlite3.connect(f"file:{source}?mode=ro", uri=True)
    target_db = sqlite3.connect(destination)
    try:
        source_db.backup(target_db)
        target_db.commit()
        if target_db.execute("PRAGMA integrity_check").fetchone()[0] != "ok":
            fail("SQLite backup integrity check failed")
    finally:
        target_db.close()
        source_db.close()
    os.chmod(destination, 0o600)
    os.chown(destination, 0, 0)


def backup_mode(args):
    destination = pathlib.Path(args.backup_dir)
    if destination.exists():
        if destination.is_symlink() or not destination.is_dir() or file_mode(destination) != 0o700:
            fail("existing Indexer and subtitle setup backup is unsafe")
        required = ("prowlarr.db", "prowlarr-config.xml", "bazarr.db", "bazarr-config.yaml", "api-state.json", "backup.json")
        if any(not (destination / name).is_file() or file_mode(destination / name) != 0o600 for name in required):
            fail("existing Indexer and subtitle setup backup is incomplete")
        print("BACKUP=PRESERVED")
        return
    parent = destination.parent
    parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    temporary = parent / f".{destination.name}.{secrets.token_hex(8)}"
    temporary.mkdir(mode=0o700)
    os.chown(temporary, 0, 0)
    try:
        config = pathlib.Path(args.config_root)
        sqlite_backup(config / "prowlarr/prowlarr.db", temporary / "prowlarr.db")
        sqlite_backup(config / "bazarr/db/bazarr.db", temporary / "bazarr.db")
        atomic_bytes(temporary / "prowlarr-config.xml", (config / "prowlarr/config.xml").read_bytes())
        atomic_bytes(temporary / "bazarr-config.yaml", (config / "bazarr/config/config.yaml").read_bytes())
        atomic_json(temporary / "api-state.json", api_snapshot(args))
        atomic_json(temporary / "backup.json", {"consistent_sqlite_backup": True, "api_rollback": True})
        os.replace(temporary, destination)
    finally:
        if temporary.exists():
            shutil.rmtree(temporary)
    print("BACKUP=CREATED")


def apply_mode(args):
    apps, bazarr, settings, languages, profiles, bazarr_series = current_state(args)
    if apps["prowlarr"].get("indexer") or profiles or settings["general"].get("enabled_providers"):
        fail("Indexer and subtitle setup must start from the verified empty foundation")
    available_languages = {item["code2"] for item in languages}
    if not {"ar", "en"} <= available_languages:
        fail("Bazarr lacks Arabic or English language support")
    if not {"embeddedsubtitles", "subtitlecat"} <= set(settings):
        fail("pinned Bazarr provider schemas changed")
    prowlarr = apps["prowlarr"]
    schemas = candidate_schemas(prowlarr)
    profiles_arr = prowlarr.get("appprofile")
    if not profiles_arr:
        fail("Prowlarr has no application profile")
    fs_tag = proxy_tag(prowlarr)
    candidate_results = []
    enabled = []
    for label, _definition in INDEXER_CANDIDATES:
        schema = schemas[label]
        if schema is None:
            candidate_results.append({"name": label, "result": "definition-unavailable", "enabled": False})
            continue
        passed, result, needs_fs = test_candidate(prowlarr, schema, profiles_arr[0]["id"], fs_tag)
        cats = categories(schema)
        capability = {"anime_tv": 5070 in cats, "movies": any(value.startswith("Movies") for value in cats.values())}
        candidate_results.append({"name": label, "result": result, "enabled": passed,
                                  "flaresolverr": needs_fs, "capabilities": capability})
        if not passed:
            continue
        resource = json.loads(json.dumps(schema))
        resource.update(name=label, enable=True, redirect=False, priority=25,
                        downloadClientId=0, appProfileId=profiles_arr[0]["id"],
                        tags=[fs_tag] if needs_fs else [])
        created = prowlarr.call("POST", "indexer", resource)
        enabled.append(created["name"])
    if not enabled:
        fail("no public Prowlarr candidate passed its official connection test")
    command = prowlarr.call("POST", "command", {"name": "ApplicationIndexerSync"})
    wait_command(prowlarr, command["id"])
    bazarr.call("POST", "system/settings", [
        ("languages-enabled", "ar"), ("languages-enabled", "en"),
        ("languages-profiles", json.dumps(profiles_payload(), separators=(",", ":"))),
        ("settings-general-enabled_providers", "embeddedsubtitles"),
        ("settings-general-enabled_providers", "subtitlecat"),
        ("settings-subtitlecat-include_machine_translated", "false"),
    ], form=True)
    # Profiles remain deliberately unassigned: assignment immediately recalculates
    # missing subtitles and a media scan is forbidden in this operation.
    report = {"candidate_indexers": candidate_results, "enabled_indexers": enabled,
              "enabled_providers": list(BAZARR_PROVIDERS), "profiles": list(PROFILE_NAMES),
              "media_scan": False, "subtitle_search": False, "download": False}
    atomic_json(args.report, report)
    print("APPLY=CONFIGURED INDEXERS=%d PROFILES=3 PROVIDERS=2" % len(enabled))


def rollback_mode(args):
    snapshot = protected_json(pathlib.Path(args.backup_dir) / "api-state.json")
    apps = app_clients(args)
    prowlarr = apps["prowlarr"]
    for item in prowlarr.get("indexer"):
        prowlarr.call("DELETE", f"indexer/{item['id']}")
    # A non-empty pre-state is supported only when its exact resources still pass.
    for item in snapshot["prowlarr"]["indexers"]:
        resource = dict(item)
        resource.pop("id", None)
        prowlarr.call("POST", "indexer/test", resource, timeout=20)
        prowlarr.call("POST", "indexer", resource)
    command = prowlarr.call("POST", "command", {"name": "ApplicationIndexerSync"})
    wait_command(prowlarr, command["id"])
    bazarr = Bazarr(read_secret(args.bazarr_key_file))
    state = snapshot["bazarr"]
    form = [("languages-enabled", item) for item in state["enabled_languages"]]
    if not form:
        form.append(("languages-enabled", ""))
    form += [("languages-profiles", json.dumps(state["profiles"], separators=(",", ":")))]
    form += [("settings-general-enabled_providers", item) for item in state["providers"]]
    if not state["providers"]:
        form.append(("settings-general-enabled_providers", ""))
    # Bazarr ignores an empty enabled-language/provider list, so the known Indexer and subtitle setup
    # zero baseline is represented explicitly by empty profiles/providers and the
    # existing language enablement is restored from the snapshot.
    bazarr.call("POST", "system/settings", form, form=True)
    for item in state["series_profiles"]:
        if item["profileid"] is not None:
            bazarr.call("POST", "series", [("seriesid", item["seriesid"]), ("profileid", item["profileid"])], form=True)
    print("ROLLBACK=API_STATE_RESTORED")


def add_common(parser):
    parser.add_argument("--username", required=True)
    parser.add_argument("--password-file", required=True)
    for name in ARR:
        parser.add_argument(f"--{name}-key-file", required=True)
    parser.add_argument("--bazarr-key-file", required=True)
    parser.add_argument("--report", required=True)


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="mode", required=True)
    backup = sub.add_parser("backup")
    add_common(backup)
    backup.add_argument("--config-root", required=True)
    backup.add_argument("--backup-dir", required=True)
    for name in ("check", "apply", "verify", "rollback"):
        command = sub.add_parser(name)
        add_common(command)
        if name == "check":
            command.add_argument("--expected-state", choices=("empty", "configured"), required=True)
        if name == "rollback":
            command.add_argument("--backup-dir", required=True)
    args = parser.parse_args()
    if args.mode == "backup":
        backup_mode(args)
    elif args.mode == "check":
        check_mode(args, args.expected_state)
    elif args.mode == "apply":
        apply_mode(args)
    elif args.mode == "verify":
        check_mode(args, "configured")
    else:
        rollback_mode(args)


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"ERROR: {error}", file=sys.stderr)
        sys.exit(1)

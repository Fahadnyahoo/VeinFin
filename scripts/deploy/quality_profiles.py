#!/usr/bin/env python3
"""Quality profile setup policy generation, API preservation, verification, and rollback."""

import argparse
import hashlib
import http.cookiejar
import json
import os
import pathlib
import re
import secrets
import shutil
import sqlite3
import sys
import urllib.error
import urllib.parse
import urllib.request


MANAGED = {
    "radarr": ("VeinFin Movies 4K",),
    "sonarr": ("VeinFin TV 1080p SDR", "VeinFin Anime 1080p SDR"),
}
REJECT_SCORE = -10000


def fail(message):
    raise RuntimeError(message)


def mode(path):
    return pathlib.Path(path).stat().st_mode & 0o777


def read_secret(path):
    path = pathlib.Path(path)
    if not path.is_file() or path.is_symlink() or mode(path) != 0o600:
        fail(f"unsafe secret file: {path.name}")
    value = path.read_text(encoding="utf-8").rstrip("\r\n")
    if not value:
        fail(f"empty secret file: {path.name}")
    return value


def atomic_bytes(path, data, uid=0, gid=0):
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
        if os.geteuid() == 0:
            os.chown(temporary, uid, gid)
        os.replace(temporary, path)
    finally:
        if temporary.exists():
            temporary.unlink()


def atomic_json(path, value, uid=0, gid=0):
    atomic_bytes(path, (json.dumps(value, indent=2, sort_keys=True) + "\n").encode(), uid, gid)


def load_json(path, protected=False):
    path = pathlib.Path(path)
    if not path.is_file() or path.is_symlink() or (protected and mode(path) != 0o600):
        fail(f"missing or unsafe file: {path.name}")
    return json.loads(path.read_text(encoding="utf-8"))


def request(method, url, body=None, headers=None, opener=None, allowed=(200, 201, 202, 204)):
    headers = dict(headers or {})
    data = None
    if body is not None:
        data = json.dumps(body, separators=(",", ":")).encode()
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, method=method, headers=headers)
    try:
        call = opener.open if opener else urllib.request.urlopen
        with call(req, timeout=30) as response:
            raw = response.read()
            if response.status not in allowed:
                fail(f"request returned HTTP {response.status}")
            return json.loads(raw) if raw else None
    except urllib.error.HTTPError as error:
        fail(f"request failed for {urllib.parse.urlsplit(url).path} (HTTP {error.code})")


class Arr:
    def __init__(self, name, key):
        self.name = name
        port = 8989 if name == "sonarr" else 7878 if name == "radarr" else 9696
        version = "v1" if name == "prowlarr" else "v3"
        self.base = f"http://127.0.0.1:{port}/api/{version}/"
        self.headers = {"X-Api-Key": key}

    def call(self, method, path, body=None):
        return request(method, self.base + path, body, self.headers)

    def get(self, path):
        return self.call("GET", path)


class Bazarr:
    def __init__(self, key):
        self.headers = {"X-API-KEY": key}

    def get(self, path):
        return request("GET", "http://127.0.0.1:6767/api/" + path, headers=self.headers)


def seerr_session(username, password):
    jar = http.cookiejar.CookieJar()
    opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))
    request("POST", "http://127.0.0.1:5055/api/v1/auth/jellyfin",
            {"username": username, "password": password}, opener=opener)
    if not list(jar):
        fail("Seerr did not establish an authenticated session")
    return opener


def seerr_call(opener, method, path, body=None):
    return request(method, "http://127.0.0.1:5055/api/v1/" + path, body, opener=opener)


def clients(args):
    return {
        name: Arr(name, read_secret(getattr(args, f"{name}_key_file")))
        for name in ("sonarr", "radarr", "prowlarr")
    }


def validate_policy(policy):
    if policy.get("schema") != 1 or set(policy.get("profiles", {})) != {"movies", "tv", "anime"}:
        fail("quality policy schema or profile set is invalid")
    expected = {"movies": ("radarr", "VeinFin Movies 4K"),
                "tv": ("sonarr", "VeinFin TV 1080p SDR"),
                "anime": ("sonarr", "VeinFin Anime 1080p SDR")}
    all_ids = []
    for key, profile in policy["profiles"].items():
        if (profile.get("application"), profile.get("name")) != expected[key]:
            fail(f"managed profile identity drifted: {key}")
        qualities = [q for item in profile["qualities"] for q in item.get("qualities", [item["name"]])]
        if any("Remux" in q or "2160" in q for q in qualities) and key != "movies":
            fail(f"{key} permits Remux or 2160p")
        if key == "movies" and (not any("2160" in q for q in qualities) or not any("1080" in q for q in qualities)):
            fail("movie policy lacks 4K or 1080p fallback")
        if any("Remux" in q for q in qualities):
            fail(f"{key} permits Remux")
        reject_names = " ".join(profile["reject"])
        required = ("AV1", "Low-quality", "Upscaled")
        if not all(word in reject_names for word in required):
            fail(f"{key} lacks mandatory rejection rules")
        if key == "movies" and "Dolby Vision without HDR10 fallback" not in profile["reject"]:
            fail("movie Dolby Vision fallback rule is absent")
        if key != "movies" and "HDR family" not in reject_names:
            fail(f"{key} does not reject HDR")
        ids = list(profile["reject"].values()) + [v["trash_id"] for v in profile["prefer"].values()]
        if any(not re.fullmatch(r"[0-9a-f]{32}", value) for value in ids):
            fail(f"{key} contains an invalid TRaSH ID")
        all_ids.extend((profile["application"], value) for value in ids)
    revisions = policy.get("resource_revisions", {})
    if revisions.get("recyclarr_version") != "8.8.0" or any(
            not re.fullmatch(r"[0-9a-f]{40}", revisions.get(key, ""))
            for key in ("config_templates", "trash_guides")):
        fail("resource revision lock is invalid")
    return policy


def yaml_quote(value):
    return json.dumps(str(value))


def render_instance(application, profiles, key):
    lines = [f"{application}:", f"  veinfin-{application}:", f"    base_url: http://{application}:{8989 if application == 'sonarr' else 7878}",
             f"    api_key: {yaml_quote(key)}", "    delete_old_custom_formats: false", "    quality_profiles:"]
    for profile in profiles:
        lines += [f"      - name: {yaml_quote(profile['name'])}", "        reset_unmatched_scores:", "          enabled: true",
                  "        upgrade:", "          allowed: true", f"          until_quality: {yaml_quote(profile['upgrade_until'])}",
                  "        min_format_score: 0", "        quality_sort: top", "        qualities:"]
        for item in profile["qualities"]:
            lines.append(f"          - name: {yaml_quote(item['name'])}")
            if "qualities" in item:
                lines.append("            qualities:")
                lines += [f"              - {yaml_quote(q)}" for q in item["qualities"]]
    lines.append("    custom_formats:")
    for profile in profiles:
        for label, trash_id in profile["reject"].items():
            lines += [f"      - trash_ids: [{yaml_quote(trash_id)}]", "        assign_scores_to:",
                      f"          - name: {yaml_quote(profile['name'])}", f"            score: {REJECT_SCORE} # {label}"]
        for label, item in profile["prefer"].items():
            lines += [f"      - trash_ids: [{yaml_quote(item['trash_id'])}]", "        assign_scores_to:",
                      f"          - name: {yaml_quote(profile['name'])}", f"            score: {int(item['score'])} # {label}"]
    return lines


def generate(args):
    policy = validate_policy(load_json(args.policy))
    grouped = {name: [] for name in ("sonarr", "radarr")}
    for profile in policy["profiles"].values():
        grouped[profile["application"]].append(profile)
    lines = []
    for app in ("sonarr", "radarr"):
        lines += render_instance(app, grouped[app], read_secret(getattr(args, f"{app}_key_file")))
    atomic_bytes(args.output, ("\n".join(lines) + "\n").encode(), args.uid, args.gid)
    print("GENERATED=1 PROFILES=3 SECRET_OUTPUT=PROTECTED")


def qbit_count(username, password):
    jar = http.cookiejar.CookieJar()
    opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))
    data = urllib.parse.urlencode({"username": username, "password": password}).encode()
    opener.open(urllib.request.Request("http://127.0.0.1:8080/api/v2/auth/login", data=data), timeout=15).read()
    return len(json.load(opener.open("http://127.0.0.1:8080/api/v2/torrents/info", timeout=15)))


def app_snapshot(args):
    apps = clients(args)
    password = read_secret(args.password_file)
    opener = seerr_session(args.username, password)
    bazarr = Bazarr(read_secret(args.bazarr_key_file))
    result = {"arr": {}, "seerr": {}, "bazarr": {}}
    for name in ("sonarr", "radarr"):
        app = apps[name]
        result["arr"][name] = {
            "quality_profiles": app.get("qualityprofile"),
            "quality_definitions": app.get("qualitydefinition"),
            "custom_formats": app.get("customformat"),
            "delay_profiles": app.get("delayprofile"),
            "naming": app.get("config/naming"),
            "media_management": app.get("config/mediamanagement"),
            "download_clients": app.get("downloadclient"),
            "root_folders": app.get("rootfolder"),
            "queue": app.get("queue?page=1&pageSize=100"),
            "history": app.get("history?page=1&pageSize=100"),
        }
    result["arr"]["sonarr"].update(series=apps["sonarr"].get("series"))
    result["arr"]["radarr"].update(movies=apps["radarr"].get("movie"))
    result["arr"]["prowlarr"] = {"indexers": apps["prowlarr"].get("indexer"), "applications": apps["prowlarr"].get("applications")}
    result["bazarr"] = {
        "settings": bazarr.get("system/settings"),
        "profiles": bazarr.get("system/languages/profiles"),
        "episodes_wanted": bazarr.get("episodes/wanted?start=0&length=1"),
        "movies_wanted": bazarr.get("movies/wanted?start=0&length=1"),
        "episodes_history": bazarr.get("episodes/history?start=0&length=1"),
        "movies_history": bazarr.get("movies/history?start=0&length=1"),
    }
    result["seerr"]["sonarr"] = seerr_call(opener, "GET", "settings/sonarr")
    result["seerr"]["radarr"] = seerr_call(opener, "GET", "settings/radarr")
    result["seerr"]["requests"] = seerr_call(opener, "GET", "request?take=1&skip=0")
    result["qbit_torrents"] = qbit_count(args.username, password)
    return result


def stable(value):
    """Remove API-generated IDs from comparison only where managed objects are expected."""
    return value


def preserved_profile_view(profile, preexisting_format_ids):
    value = json.loads(json.dumps(profile))
    value["formatItems"] = sorted(
        (item for item in value.get("formatItems", []) if item.get("format") in preexisting_format_ids),
        key=lambda item: item.get("format", 0))
    return value


def check_initial(snapshot):
    for app in ("sonarr", "radarr"):
        names = {item["name"] for item in snapshot["arr"][app]["quality_profiles"]}
        if names & set(MANAGED[app]):
            fail("managed quality profile already exists without a completion marker")
        if snapshot["arr"][app]["custom_formats"]:
            fail("pre-quality-profile custom-format state is not empty")
    series = snapshot["arr"]["sonarr"]["series"]
    if len(series) != 1 or series[0].get("monitored") or series[0].get("qualityProfileId") is None:
        fail("existing Sonarr series baseline changed")
    if snapshot["arr"]["radarr"]["movies"]:
        fail("Radarr is not empty")
    if snapshot["qbit_torrents"] != 0:
        fail("qBittorrent contains torrents")
    if int(snapshot["seerr"]["requests"].get("pageInfo", {}).get("results", -1)) != 0:
        fail("Seerr contains requests")
    for key in ("episodes_wanted", "movies_wanted", "episodes_history", "movies_history"):
        if int(snapshot["bazarr"][key].get("total", -1)) != 0:
            fail("Bazarr contains wanted or history activity")


def snapshot_mode(args):
    snapshot = app_snapshot(args)
    if args.expect == "initial":
        check_initial(snapshot)
    atomic_json(args.output, snapshot)
    print("SNAPSHOT=RECORDED")


def sqlite_backup(source, destination):
    source_db = sqlite3.connect(f"file:{source}?mode=ro", uri=True)
    target_db = sqlite3.connect(destination)
    try:
        source_db.backup(target_db)
        if target_db.execute("PRAGMA integrity_check").fetchone()[0] != "ok":
            fail(f"backup integrity check failed: {pathlib.Path(source).name}")
    finally:
        target_db.close()
        source_db.close()
    os.chmod(destination, 0o600)
    if os.geteuid() == 0:
        os.chown(destination, 0, 0)


def backup_mode(args):
    destination = pathlib.Path(args.backup_dir)
    required = ("sonarr.db", "radarr.db", "seerr.db", "sonarr-config.xml", "radarr-config.xml",
                "seerr-settings.json", "api-state.json", "manifest.json", "recyclarr-config", "recyclarr-data")
    if destination.exists():
        if destination.is_symlink() or not destination.is_dir() or mode(destination) != 0o700:
            fail("existing Quality profile setup backup is unsafe")
        if any(not (destination / name).exists() for name in required):
            fail("existing Quality profile setup backup is incomplete")
        for name in required[:8]:
            if mode(destination / name) != 0o600:
                fail("existing Quality profile setup backup permissions are unsafe")
        for name in ("sonarr.db", "radarr.db", "seerr.db"):
            db = sqlite3.connect(f"file:{destination / name}?mode=ro", uri=True)
            try:
                if db.execute("PRAGMA integrity_check").fetchone()[0] != "ok":
                    fail(f"existing backup is corrupt: {name}")
            finally:
                db.close()
        print("BACKUP=PRESERVED INTEGRITY=PASS")
        return
    temporary = destination.parent / f".{destination.name}.{secrets.token_hex(8)}"
    temporary.mkdir(mode=0o700, parents=False)
    config = pathlib.Path(args.config_root)
    try:
        sqlite_backup(config / "sonarr/sonarr.db", temporary / "sonarr.db")
        sqlite_backup(config / "radarr/radarr.db", temporary / "radarr.db")
        sqlite_backup(config / "seerr/db/db.sqlite3", temporary / "seerr.db")
        for source, name in ((config / "sonarr/config.xml", "sonarr-config.xml"),
                             (config / "radarr/config.xml", "radarr-config.xml"),
                             (config / "seerr/settings.json", "seerr-settings.json"),
                             (pathlib.Path(args.before), "api-state.json")):
            data = source.read_bytes()
            atomic_bytes(temporary / name, data)
        for source, name in ((pathlib.Path(args.recyclarr_config), "recyclarr-config"),
                             (config / "recyclarr", "recyclarr-data")):
            shutil.copytree(source, temporary / name, symlinks=False)
            for root, directories, files in os.walk(temporary / name):
                os.chmod(root, 0o700)
                if os.geteuid() == 0:
                    os.chown(root, 0, 0)
                for filename in files:
                    target = pathlib.Path(root, filename)
                    os.chmod(target, 0o600)
                    if os.geteuid() == 0:
                        os.chown(target, 0, 0)
        manifest = {"schema": 1, "databases": ["sonarr.db", "radarr.db", "seerr.db"],
                    "database_integrity": "ok", "media_included": False,
                    "database_restore_requires_guarded_container_stop": True}
        atomic_json(temporary / "manifest.json", manifest)
        os.replace(temporary, destination)
    finally:
        if temporary.exists():
            shutil.rmtree(temporary)
    print("BACKUP=CREATED INTEGRITY=PASS MEDIA_INCLUDED=0")


def media_verify(args):
    expected = load_json(args.snapshot, protected=True).get("files", {})
    root = pathlib.Path(args.media_path).resolve()
    if not root.is_dir() or root.is_symlink() or not str(root).startswith("/srv/media/library/anime/"):
        fail("media verification path is unavailable or unsafe")
    actual = {}
    for path in sorted(root.rglob("*")):
        if path.is_symlink():
            fail("media tree contains a symbolic link")
        if path.is_file():
            stat = path.stat()
            actual[path.relative_to(root).as_posix()] = {"size": stat.st_size, "mtime_ns": stat.st_mtime_ns}
    if actual != expected:
        fail("media paths, sizes, or nanosecond timestamps changed")
    print(f"MEDIA=UNCHANGED FILES={len(actual)}")


def profile_allowed(profile):
    result = []
    def walk(items):
        for item in items:
            quality = item.get("quality") or {}
            if item.get("allowed") and quality.get("name"):
                result.append(quality["name"])
            walk(item.get("items") or [])
    walk(profile.get("items") or [])
    return result


def verify_managed(args, before):
    policy = validate_policy(load_json(args.policy))
    now = app_snapshot(args)
    if now["qbit_torrents"] != 0 or now["arr"]["radarr"]["movies"]:
        fail("download or movie state changed")
    old_series, new_series = before["arr"]["sonarr"]["series"], now["arr"]["sonarr"]["series"]
    if new_series != old_series:
        fail("existing Sonarr series assignment or monitoring changed")
    for app in ("sonarr", "radarr"):
        old = before["arr"][app]
        current = now["arr"][app]
        for key in ("quality_definitions", "delay_profiles", "naming", "media_management", "download_clients", "root_folders", "queue", "history"):
            if current[key] != old[key]:
                fail(f"unrelated {app} {key} changed")
        old_profiles = {x["name"]: x for x in old["quality_profiles"]}
        current_profiles = {x["name"]: x for x in current["quality_profiles"]}
        original_format_ids = {x["id"] for x in old["custom_formats"]}
        for name, value in old_profiles.items():
            if name not in current_profiles or preserved_profile_view(current_profiles[name], original_format_ids) != preserved_profile_view(value, original_format_ids):
                fail(f"unrelated {app} profile changed: {name}")
        if set(current_profiles) != set(old_profiles) | set(MANAGED[app]):
            fail(f"{app} managed profile set is not exact")
        policy_ids = {
            trash_id
            for profile in policy["profiles"].values() if profile["application"] == app
            for trash_id in list(profile["reject"].values()) + [item["trash_id"] for item in profile["prefer"].values()]
        }
        if len(current["custom_formats"]) != len(old["custom_formats"]) + len(policy_ids):
            fail(f"{app} custom-format set is not exact")
    for key, expected in policy["profiles"].items():
        app = expected["application"]
        actual = next(x for x in now["arr"][app]["quality_profiles"] if x["name"] == expected["name"])
        allowed = set(profile_allowed(actual))
        wanted = {q for item in expected["qualities"] for q in item.get("qualities", [item["name"]])}
        if allowed != wanted:
            fail(f"{key} allowed qualities drifted")
        if key in ("tv", "anime"):
            definitions = {(item.get("quality") or {}).get("name"): item for item in now["arr"][app]["quality_definitions"]}
            if any(quality not in definitions or not isinstance(definitions[quality].get("maxSize"), (int, float))
                   or definitions[quality]["maxSize"] <= 0 for quality in wanted):
                fail(f"{key} does not inherit a finite maximum size for every allowed quality")
        scores = {item.get("format"): item.get("score") for item in actual.get("formatItems", [])}
        formats = {item["id"]: item for item in now["arr"][app]["custom_formats"]}
        names_to_score = {formats[i]["name"]: score for i, score in scores.items() if i in formats}
        if list(scores.values()).count(REJECT_SCORE) < len(expected["reject"]):
            fail(f"{key} rejection scores are incomplete")
        expected_positive = sorted(item["score"] for item in expected["prefer"].values())
        if not all(list(scores.values()).count(score) >= expected_positive.count(score) for score in set(expected_positive)):
            fail(f"{key} preference scores are incomplete")
        if any(score < 0 for name, score in names_to_score.items() if name.lower() == "hdr") and key == "movies":
            fail("movie HDR was incorrectly rejected")
    if before["arr"]["prowlarr"] != now["arr"]["prowlarr"]:
        fail("Prowlarr configuration changed")
    if before["bazarr"] != now["bazarr"]:
        fail("Bazarr configuration or activity changed")
    if int(now["seerr"]["requests"].get("pageInfo", {}).get("results", -1)) != 0:
        fail("Seerr request state changed")
    return now


def update_seerr(args, restore=False):
    before = load_json(args.before, protected=True)
    opener = seerr_session(args.username, read_secret(args.password_file))
    if restore:
        targets = before["seerr"]
    else:
        apps = clients(args)
        profile_ids = {}
        for app in ("sonarr", "radarr"):
            profile_ids[app] = {x["name"]: x["id"] for x in apps[app].get("qualityprofile")}
        targets = {kind: json.loads(json.dumps(before["seerr"][kind])) for kind in ("sonarr", "radarr")}
        if len(targets["sonarr"]) != 1 or len(targets["radarr"]) != 1:
            fail("Seerr connection set is not exact")
        sonarr, radarr = targets["sonarr"][0], targets["radarr"][0]
        sonarr["activeProfileId"] = profile_ids["sonarr"]["VeinFin TV 1080p SDR"]
        sonarr["activeProfileName"] = "VeinFin TV 1080p SDR"
        # Seerr supports an explicit anime default on its single Sonarr connection.
        sonarr["activeAnimeProfileId"] = profile_ids["sonarr"]["VeinFin Anime 1080p SDR"]
        sonarr["activeAnimeProfileName"] = "VeinFin Anime 1080p SDR"
        radarr["activeProfileId"] = profile_ids["radarr"]["VeinFin Movies 4K"]
        radarr["activeProfileName"] = "VeinFin Movies 4K"
    for kind in ("sonarr", "radarr"):
        if len(targets[kind]) != 1:
            fail(f"Seerr {kind} connection set is not exact")
        body = dict(targets[kind][0])
        identifier = body.pop("id")
        seerr_call(opener, "PUT", f"settings/{kind}/{identifier}", body)
    print("SEERR=" + ("RESTORED" if restore else "DEFAULTS_UPDATED"))


def verify_mode(args):
    before = load_json(args.before, protected=True)
    now = verify_managed(args, before)
    sonarr, radarr = now["seerr"]["sonarr"], now["seerr"]["radarr"]
    if len(sonarr) != 1 or len(radarr) != 1:
        fail("Seerr connections changed")
    if (sonarr[0].get("activeProfileName"), sonarr[0].get("activeAnimeProfileName"), radarr[0].get("activeProfileName")) != (
            "VeinFin TV 1080p SDR", "VeinFin Anime 1080p SDR", "VeinFin Movies 4K"):
        fail("Seerr defaults are incorrect")
    if not sonarr[0].get("preventSearch") or not radarr[0].get("preventSearch"):
        fail("Seerr search prevention changed")
    print("VERIFY=PASS PROFILES=3 TORRENTS=0 REQUESTS=0 CONTENT_ASSIGNMENTS=UNCHANGED")


def rollback_mode(args):
    before = load_json(args.before, protected=True)
    apps = clients(args)
    update_seerr(args, restore=True)
    for app_name in ("sonarr", "radarr"):
        app = apps[app_name]
        original_profiles = {x["name"]: x for x in before["arr"][app_name]["quality_profiles"]}
        for current in app.get("qualityprofile"):
            if current["name"] in MANAGED[app_name] and current["name"] not in original_profiles:
                app.call("DELETE", f"qualityprofile/{current['id']}")
        original_formats = {x["id"]: x for x in before["arr"][app_name]["custom_formats"]}
        for current in app.get("customformat"):
            if current["id"] not in original_formats:
                app.call("DELETE", f"customformat/{current['id']}")
        for resource in original_formats.values():
            app.call("PUT", f"customformat/{resource['id']}", resource)
    check_initial(app_snapshot(args))
    print("ROLLBACK=PASS MEDIA_UNTOUCHED=1")


def preview_summary(args):
    policy = validate_policy(load_json(args.policy))
    raw = pathlib.Path(args.preview).read_bytes()
    text = raw.decode(errors="replace")
    secrets_to_find = [read_secret(args.sonarr_key_file), read_secret(args.radarr_key_file)]
    if any(value in text for value in secrets_to_find):
        fail("official preview exposed an API key")
    for profile in policy["profiles"].values():
        if profile["name"] not in text:
            fail(f"official preview omitted managed profile: {profile['name']}")
    required_markers = ("Processing Sonarr server veinfin-sonarr", "Processing Radarr server veinfin-radarr",
                        "No quality_definition configured, skipping quality sizes")
    if not all(marker in text for marker in required_markers):
        fail("official preview omitted an expected bounded plan marker")
    if re.search(r"(?im)^\[(?:WRN|ERR|FTL)\]", text) or re.search(
            r"(?im)^\[INF\].*(?:delete|remove).*(?:profile|quality)|^\[INF\].*(?:search|download|monitor|rename)", text):
        fail("official preview proposes or reports an out-of-scope change")
    summary = {
        "schema": 1,
        "official_preview_sha256": hashlib.sha256(raw).hexdigest(),
        "generated_config_sha256": hashlib.sha256(pathlib.Path(args.config).read_bytes()).hexdigest(),
        "resource_revisions": policy["resource_revisions"],
        "profiles": [],
        "safety": {"searches": False, "downloads": False, "assignments": False,
                   "naming_changes": False, "media_management_changes": False},
    }
    for key, profile in policy["profiles"].items():
        summary["profiles"].append({
            "key": key, "name": profile["name"], "application": profile["application"],
            "qualities": profile["qualities"], "reject_count": len(profile["reject"]),
            "preference_count": len(profile["prefer"]),
        })
    atomic_json(args.output, summary)
    print("PREVIEW_GATE=PASS PROFILES=3 DRIFT=0")


def parser():
    value = argparse.ArgumentParser()
    value.add_argument("mode", choices=("validate-policy", "generate", "snapshot", "backup", "media-verify", "preview-summary", "seerr-apply", "verify", "rollback"))
    value.add_argument("--policy")
    value.add_argument("--output")
    value.add_argument("--preview")
    value.add_argument("--config")
    value.add_argument("--before")
    value.add_argument("--backup-dir")
    value.add_argument("--config-root")
    value.add_argument("--recyclarr-config")
    value.add_argument("--snapshot")
    value.add_argument("--media-path")
    value.add_argument("--expect", choices=("initial", "any"), default="any")
    value.add_argument("--username")
    value.add_argument("--password-file")
    for name in ("sonarr", "radarr", "prowlarr"):
        value.add_argument(f"--{name}-key-file")
    value.add_argument("--bazarr-key-file")
    value.add_argument("--uid", type=int, default=0)
    value.add_argument("--gid", type=int, default=0)
    return value


def main():
    args = parser().parse_args()
    if args.mode == "validate-policy":
        validate_policy(load_json(args.policy)); print("POLICY=VALID")
    elif args.mode == "generate": generate(args)
    elif args.mode == "snapshot": snapshot_mode(args)
    elif args.mode == "backup": backup_mode(args)
    elif args.mode == "media-verify": media_verify(args)
    elif args.mode == "preview-summary": preview_summary(args)
    elif args.mode == "seerr-apply": update_seerr(args)
    elif args.mode == "verify": verify_mode(args)
    elif args.mode == "rollback": rollback_mode(args)


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, ValueError, KeyError, OSError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        sys.exit(1)

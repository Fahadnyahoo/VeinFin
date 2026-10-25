#!/usr/bin/env python3
"""Validate, stage, and inspect the exact VeinFin Jellyfin plugin allowlist."""

import argparse
import hashlib
import json
import os
import pathlib
import re
import secrets
import stat
import sys
import urllib.error
import urllib.parse
import urllib.request
import uuid
import zipfile

FIELDS = ("key", "name", "guid", "version", "target_abi", "license", "repository",
          "artifact_url", "artifact_sha256", "restart", "required_files")
SAFE_ARTIFACTS = (
    re.compile(r"https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/releases/download/(?:[^/]+/)+[^/]+\.zip$"),
    re.compile(r"https://repo\.jellyfin\.org/files/plugin/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\.zip$"),
)
HEX64 = re.compile(r"[0-9a-f]{64}")
VERSION = re.compile(r"\d+\.\d+\.\d+\.\d+")
DESIRED_CONFIGURATION = {
    "INTRO_SKIPPER": {
        "AutoDetectIntros": True,
        "UpdateMediaSegments": True,
        "UseFileTransformationPlugin": False,
        "EnableMainMenu": True,
    },
}
PROFILE_SCHEMA_VERSION = 1
ENHANCED_GUID = "f69e946a-4b3c-4e9a-8f0a-8d7c1b2c4d9b"
ENHANCED_VERSION = "12.13.0.0"
PROFILE_CATEGORIES = ("installation_specific", "secret", "user_specific_state")
REQUIRED_SECRET_SETTINGS = {
    "AnalyticsInstallSecret", "DoesTheDogDieApiKey", "JellyseerrApiKey",
    "MdblistApiKey", "RadarrApiKey", "ShokoApiKey", "SonarrApiKey", "TMDB_API_KEY",
}
REQUIRED_INSTALLATION_SETTINGS = {
    "BazarrUrl", "BazarrUrlMappings", "JellyseerrUrls", "JellyseerrUrlMappings",
    "RadarrInstances", "RadarrUrl", "RadarrUrlMappings", "SonarrInstances",
    "SonarrUrl", "SonarrUrlMappings",
}


def fail(message):
    raise RuntimeError(message)


def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def parse_lock(path):
    entries = []
    seen = {"key": set(), "guid": set(), "name": set()}
    for number, raw in enumerate(pathlib.Path(path).read_text(encoding="utf-8").splitlines(), 1):
        if not raw or raw.startswith("#"):
            continue
        parts = raw.split("|", len(FIELDS) - 1)
        if len(parts) != len(FIELDS) or any(not value for value in parts):
            fail(f"plugins.lock line {number} is malformed")
        item = dict(zip(FIELDS, parts))
        if not re.fullmatch(r"[A-Z][A-Z0-9_]+", item["key"]):
            fail(f"plugins.lock line {number} has an invalid key")
        if "who" in item["name"].lower() or "watching" in item["name"].lower():
            fail("deferred Who's Watching material is forbidden")
        try:
            uuid.UUID(item["guid"])
        except ValueError:
            fail(f"plugins.lock line {number} has an invalid GUID")
        if not VERSION.fullmatch(item["version"]) or not VERSION.fullmatch(item["target_abi"]):
            fail(f"plugins.lock line {number} has an invalid version")
        if item["restart"] != "true":
            fail(f"plugins.lock line {number} must declare restart behavior")
        if not item["repository"].startswith("https://github.com/"):
            fail(f"plugins.lock line {number} has a non-official repository URL")
        if not any(pattern.fullmatch(item["artifact_url"]) for pattern in SAFE_ARTIFACTS):
            fail(f"plugins.lock line {number} has a non-allowlisted artifact URL")
        if not HEX64.fullmatch(item["artifact_sha256"]):
            fail(f"plugins.lock line {number} has an invalid artifact SHA-256")
        files = {}
        for spec in item["required_files"].split(","):
            name, separator, digest = spec.partition("=")
            pure = pathlib.PurePosixPath(name)
            if not separator or pure.is_absolute() or len(pure.parts) != 1 or name in files or not HEX64.fullmatch(digest):
                fail(f"plugins.lock line {number} has an invalid required-file contract")
            files[name] = digest
        item["files"] = files
        for field in seen:
            value = item[field].lower()
            if value in seen[field]:
                fail(f"plugins.lock line {number} duplicates {field}")
            seen[field].add(value)
        entries.append(item)
    if not entries:
        fail("supported plugin lock is empty")
    return entries


def verify_archive(entry, archive, destination):
    if sha256(archive) != entry["artifact_sha256"]:
        fail(f"artifact hash mismatch for {entry['name']}")
    destination = pathlib.Path(destination)
    temporary = destination.parent / f".{destination.name}.{secrets.token_hex(8)}"
    temporary.mkdir(mode=0o700)
    try:
        with zipfile.ZipFile(archive) as bundle:
            names = []
            for info in bundle.infolist():
                pure = pathlib.PurePosixPath(info.filename)
                mode = info.external_attr >> 16
                if pure.is_absolute() or ".." in pure.parts or len(pure.parts) != 1 or stat.S_ISLNK(mode):
                    fail(f"unsafe archive member for {entry['name']}")
                if info.is_dir():
                    continue
                names.append(info.filename)
                if info.filename not in entry["files"]:
                    fail(f"unexpected archive member for {entry['name']}")
                target = temporary / info.filename
                with bundle.open(info) as source, open(target, "xb") as output:
                    while block := source.read(1024 * 1024):
                        output.write(block)
                os.chmod(target, 0o600)
                if sha256(target) != entry["files"][info.filename]:
                    fail(f"file hash mismatch for {entry['name']}")
            if set(names) != set(entry["files"]):
                fail(f"archive contents incomplete for {entry['name']}")
        os.replace(temporary, destination)
    finally:
        if temporary.exists():
            for child in temporary.iterdir():
                child.unlink()
            temporary.rmdir()


def stage(entries, output, source_dir=None):
    root = pathlib.Path(output)
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(root, 0o700)
    for entry in entries:
        final = root / f"{entry['key']}-{entry['version']}"
        if final.exists():
            for name, digest in entry["files"].items():
                if not (final / name).is_file() or sha256(final / name) != digest:
                    fail(f"existing staged files are invalid for {entry['name']}")
            continue
        archive = pathlib.Path(source_dir) / pathlib.PurePosixPath(entry["artifact_url"]).name if source_dir else root / f".{entry['key']}.zip"
        downloaded = source_dir is None
        try:
            if downloaded:
                with urllib.request.urlopen(entry["artifact_url"], timeout=60) as response, open(archive, "xb") as stream:
                    while block := response.read(1024 * 1024):
                        stream.write(block)
                os.chmod(archive, 0o600)
            if not archive.is_file():
                fail(f"reviewed artifact is unavailable for {entry['name']}")
            verify_archive(entry, archive, final)
        finally:
            if downloaded and archive.exists():
                archive.unlink()


def read_secret(path):
    value_path = pathlib.Path(path)
    if not value_path.is_file() or value_path.is_symlink() or stat.S_IMODE(value_path.stat().st_mode) != 0o600:
        fail("protected secret file is missing or unsafe")
    value = value_path.read_text(encoding="utf-8").rstrip("\r\n")
    if not value:
        fail("protected secret file is empty")
    return value


def read_optional_secret(path):
    value_path = pathlib.Path(path)
    if not value_path.exists():
        return ""
    return read_secret(value_path)


def load_enhanced_profile(path):
    profile_path = pathlib.Path(path)
    if not profile_path.is_file() or profile_path.is_symlink():
        fail("Jellyfin Enhanced profile is missing or unsafe")
    profile = json.loads(profile_path.read_text(encoding="utf-8"))
    expected_top = {"schema_version", "plugin_guid", "plugin_version", "classification",
                    "safe_portable_defaults"}
    if set(profile) != expected_top or profile.get("schema_version") != PROFILE_SCHEMA_VERSION:
        fail("Jellyfin Enhanced profile schema is invalid")
    if profile.get("plugin_guid") != ENHANCED_GUID or profile.get("plugin_version") != ENHANCED_VERSION:
        fail("Jellyfin Enhanced profile targets an unsupported plugin")
    classification = profile.get("classification")
    portable = profile.get("safe_portable_defaults")
    if not isinstance(classification, dict) or set(classification) != set(PROFILE_CATEGORIES) or not isinstance(portable, dict):
        fail("Jellyfin Enhanced profile classification is incomplete")
    category_sets = {}
    for category in PROFILE_CATEGORIES:
        values = classification[category]
        if not isinstance(values, list) or values != sorted(values) or len(values) != len(set(values)) \
                or any(not isinstance(value, str) or not value for value in values):
            fail(f"Jellyfin Enhanced {category} classification is invalid")
        category_sets[category] = set(values)
    sets = [set(portable), *category_sets.values()]
    for index, left in enumerate(sets):
        if any(left & right for right in sets[index + 1:]):
            fail("Jellyfin Enhanced profile classifications overlap")
    if not REQUIRED_SECRET_SETTINGS <= category_sets["secret"]:
        fail("Jellyfin Enhanced profile misclassifies a required secret")
    if not REQUIRED_INSTALLATION_SETTINGS <= category_sets["installation_specific"]:
        fail("Jellyfin Enhanced profile misclassifies an installation-specific value")
    for key in portable:
        if re.search(r"(?:api.?key|password|secret|token)$", key, re.IGNORECASE):
            fail("Jellyfin Enhanced profile contains a secret-shaped portable setting")
    serialized = json.dumps(portable, sort_keys=True, separators=(",", ":"))
    if re.search(r"https?://", serialized, re.IGNORECASE):
        fail("Jellyfin Enhanced portable defaults contain an endpoint")
    required = {
        "AnalyticsEnabled": False,
        "ArrLinksEnabled": True,
        "JellyseerrEnabled": True,
        "JellyseerrShowSearchResults": True,
    }
    if any(portable.get(key) != value for key, value in required.items()):
        fail("Jellyfin Enhanced portable integration defaults are invalid")
    return profile


def validate_profile_schema(configuration, profile):
    classified = set(profile["safe_portable_defaults"])
    for category in PROFILE_CATEGORIES:
        classified.update(profile["classification"][category])
    if set(configuration) != classified:
        fail("Jellyfin Enhanced live schema does not match the reviewed profile classification")


def read_env(path):
    env_path = pathlib.Path(path)
    if not env_path.is_file() or env_path.is_symlink() or stat.S_IMODE(env_path.stat().st_mode) != 0o600:
        fail("runtime environment file is missing or unsafe")
    values = {}
    for raw in env_path.read_text(encoding="utf-8").splitlines():
        if not raw or raw.startswith("#"):
            continue
        key, separator, value = raw.partition("=")
        if separator and key not in values:
            values[key] = value
        elif separator:
            fail(f"runtime environment contains duplicate key: {key}")
    return values


def management_url(env, service):
    scheme = env.get("MANAGEMENT_URL_SCHEME", "http")
    host = env.get("MANAGEMENT_URL_HOST", "")
    port = env.get(f"{service.upper()}_MANAGEMENT_PORT", "")
    if scheme not in ("http", "https") or not host or any(character in host for character in "/?#@"):
        fail("management URL settings are invalid")
    if not port.isdigit() or not 1 <= int(port) <= 65535:
        fail(f"{service} management port is invalid")
    return f"{scheme}://{host}:{port}"


def integration_configuration(profile_path, sonarr_key_file, radarr_key_file, seerr_key_file,
                              tmdb_key_file):
    profile = load_enhanced_profile(profile_path)
    sonarr_key = read_secret(sonarr_key_file)
    radarr_key = read_secret(radarr_key_file)
    seerr_key = read_secret(seerr_key_file)
    tmdb_key = read_optional_secret(tmdb_key_file)
    sonarr_instances = [{"Name": "TV & Anime", "Url": "http://sonarr:8989",
                         "ApiKey": sonarr_key, "UrlMappings": "", "Enabled": True}]
    radarr_instances = [{"Name": "Movies", "Url": "http://radarr:7878",
                         "ApiKey": radarr_key, "UrlMappings": "", "Enabled": True}]
    desired = dict(profile["safe_portable_defaults"])
    desired.update({
        "SonarrInstances": json.dumps(sonarr_instances, separators=(",", ":")),
        "RadarrInstances": json.dumps(radarr_instances, separators=(",", ":")),
        "SonarrUrl": "http://sonarr:8989",
        "SonarrApiKey": sonarr_key,
        "SonarrUrlMappings": "",
        "RadarrUrl": "http://radarr:7878",
        "RadarrApiKey": radarr_key,
        "RadarrUrlMappings": "",
        "BazarrUrl": "http://bazarr:6767",
        "BazarrUrlMappings": "",
        "JellyseerrUrls": "http://seerr:5055",
        "JellyseerrApiKey": seerr_key,
        "JellyseerrUrlMappings": "",
        "TMDB_API_KEY": tmdb_key,
    })
    return profile, desired


def request(method, path, token=None, body=None, base_url="http://127.0.0.1:8096", extra_headers=None):
    authorization = 'MediaBrowser Client="VeinFin", Device="plugins", DeviceId="veinfin_plugins", Version="1.0"'
    if token:
        authorization += f', Token="{token}"'
    headers = {"Authorization": authorization}
    headers.update(extra_headers or {})
    data = None
    if body is not None:
        data = json.dumps(body, separators=(",", ":")).encode()
        headers["Content-Type"] = "application/json"
    try:
        with urllib.request.urlopen(urllib.request.Request(base_url.rstrip("/") + path, data=data, method=method, headers=headers), timeout=30) as response:
            raw = response.read()
            return json.loads(raw) if raw else None
    except urllib.error.HTTPError as error:
        fail(f"Jellyfin API {path.split('?')[0]} returned HTTP {error.code}")


def login(username, password_file, base_url="http://127.0.0.1:8096"):
    result = request("POST", "/Users/AuthenticateByName", body={"Username": username, "Pw": read_secret(password_file)}, base_url=base_url)
    token = result.get("AccessToken", "")
    user = result.get("User", {})
    if not token or not user.get("Policy", {}).get("IsAdministrator"):
        fail("Jellyfin administrator authentication failed")
    return token, user


def live_state(username, password_file, entries, base_url="http://127.0.0.1:8096"):
    token, user = login(username, password_file, base_url)
    try:
        info = request("GET", "/System/Info", token, base_url=base_url)
        plugins = request("GET", "/Plugins", token, base_url=base_url)
        users = request("GET", "/Users", token, base_url=base_url)
        folders = request("GET", "/Library/VirtualFolders", token, base_url=base_url)
        items = request("GET", f"/Users/{user['Id']}/Items?Recursive=true&Fields=UserData&IncludeItemTypes=Series,Season,Episode,Movie", token, base_url=base_url)
        counts = {}
        watched = in_progress = 0
        for item in items.get("Items", []):
            kind = item.get("Type", "Unknown")
            counts[kind] = counts.get(kind, 0) + 1
            data = item.get("UserData") or {}
            watched += bool(data.get("Played"))
            in_progress += bool(data.get("PlaybackPositionTicks"))
        installed_ids = {(plugin.get("Id") or "").replace("-", "").lower() for plugin in plugins}
        configurations = {}
        for entry in entries:
            if entry["key"] in DESIRED_CONFIGURATION and entry["guid"].replace("-", "").lower() in installed_ids:
                configuration = request("GET", f"/Plugins/{entry['guid']}/Configuration", token, base_url=base_url)
                configurations[entry["key"]] = {key: configuration.get(key) for key in DESIRED_CONFIGURATION[entry["key"]]}
        return {"version": info.get("Version"), "users": len(users),
                "libraries": sorted(folder.get("Name", "") for folder in folders),
                "counts": counts, "watched": watched, "in_progress": in_progress,
                "plugins": sorted(({"name": p.get("Name"), "version": p.get("Version"), "status": p.get("Status"), "id": p.get("Id")} for p in plugins), key=lambda p: p["name"] or ""),
                "configuration": configurations}
    finally:
        try:
            request("POST", "/Sessions/Logout", token, base_url=base_url)
        except RuntimeError:
            pass


def atomic_json(path, value):
    target = pathlib.Path(path)
    if not target.parent.exists():
        target.parent.mkdir(mode=0o700, parents=True)
    if not target.parent.is_dir() or target.parent.is_symlink():
        fail("output parent is missing or unsafe")
    temporary = target.parent / f".{target.name}.{secrets.token_hex(8)}"
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as stream:
        json.dump(value, stream, sort_keys=True, separators=(",", ":"))
        stream.write("\n")
        stream.flush(); os.fsync(stream.fileno())
    os.replace(temporary, target)


def verify_live(entries, state, baseline=None, expected_version="12.3.0"):
    if state["version"] != expected_version:
        fail(f"live Jellyfin version is not the reviewed {expected_version} target")
    installed = {p["id"].replace("-", "").lower(): p for p in state["plugins"] if p.get("id")}
    for entry in entries:
        plugin = installed.get(entry["guid"].replace("-", "").lower())
        if not plugin or plugin["version"] != entry["version"] or plugin["status"] != "Active":
            fail(f"{entry['name']} is not active at its locked version")
    if any("who" in (p.get("name") or "").lower() and "watch" in (p.get("name") or "").lower() for p in state["plugins"]):
        fail("deferred Who's Watching plugin is installed")
    for key, expected in DESIRED_CONFIGURATION.items():
        if state.get("configuration", {}).get(key) != expected:
            fail(f"{key} supported configuration does not match the reviewed contract")
    if baseline:
        previous = json.loads(pathlib.Path(baseline).read_text(encoding="utf-8"))
        for key in ("users", "libraries", "counts", "watched", "in_progress"):
            if state[key] != previous[key]:
                fail(f"protected Jellyfin state changed: {key}")


def configure_live(entries, username, password_file, base_url="http://127.0.0.1:8096"):
    token, _user = login(username, password_file, base_url)
    try:
        by_key = {entry["key"]: entry for entry in entries}
        for key, desired in DESIRED_CONFIGURATION.items():
            entry = by_key[key]
            path = f"/Plugins/{entry['guid']}/Configuration"
            configuration = request("GET", path, token, base_url=base_url)
            missing = [name for name in desired if name not in configuration]
            if missing:
                fail(f"{entry['name']} configuration schema is missing reviewed fields")
            configuration.update(desired)
            request("POST", path, token, configuration, base_url=base_url)
            actual = request("GET", path, token, base_url=base_url)
            if any(actual.get(name) != value for name, value in desired.items()):
                fail(f"{entry['name']} configuration did not persist")
    finally:
        try:
            request("POST", "/Sessions/Logout", token, base_url=base_url)
        except RuntimeError:
            pass


def validate_arr_connections(token, desired, base_url):
    for service in ("sonarr", "radarr"):
        title = service.title()
        url = desired[f"{title}Url"]
        key = desired[f"{title}ApiKey"]
        query = urllib.parse.urlencode({"url": url})
        result = request("GET", f"/JellyfinEnhanced/arr/validate/{service}?{query}", token,
                         base_url=base_url, extra_headers={"X-Arr-ApiKey": key})
        if not result or result.get("ok") is not True:
            fail(f"Jellyfin Enhanced {title} connection check failed")


def validate_bazarr_connection(key_file, port="6767"):
    if not str(port).isdigit() or not 1 <= int(port) <= 65535:
        fail("Bazarr loopback port is invalid")
    result = request("GET", "/api/system/status", base_url=f"http://127.0.0.1:{port}",
                     extra_headers={"X-API-KEY": read_secret(key_file)})
    if not isinstance(result, dict):
        fail("Bazarr connection check returned an invalid response")


def validate_seerr_connection(token, desired, base_url):
    query = urllib.parse.urlencode({"url": desired["JellyseerrUrls"]})
    result = request("GET", f"/JellyfinEnhanced/jellyseerr/validate?{query}", token,
                     base_url=base_url, extra_headers={"X-Arr-ApiKey": desired["JellyseerrApiKey"]})
    if not result or result.get("ok") is not True:
        fail("Jellyfin Enhanced Seerr connection check failed")


def verify_seerr_search(token, base_url):
    query = urllib.parse.urlencode({"query": "the", "page": 1})
    result = request("GET", f"/JellyfinEnhanced/jellyseerr/search?{query}", token, base_url=base_url)
    items = result.get("results", []) if isinstance(result, dict) else []
    unavailable = {item.get("mediaType") for item in items
                   if item.get("mediaType") in ("movie", "tv") and not item.get("mediaInfo")}
    if unavailable != {"movie", "tv"}:
        fail("Jellyfin Enhanced search did not return unavailable movie and show results")


def verify_integrations(entries, username, password_file, profile, desired, bazarr_key_file,
                        base_url="http://127.0.0.1:8096", test_connections=True):
    token, _user = login(username, password_file, base_url)
    try:
        entry = next(item for item in entries if item["key"] == "JELLYFIN_ENHANCED")
        path = f"/Plugins/{entry['guid']}/Configuration"
        actual = request("GET", path, token, base_url=base_url)
        validate_profile_schema(actual, profile)
        if any(actual.get(name) != value for name, value in desired.items()):
            fail("Jellyfin Enhanced configuration does not match the versioned profile")
        if test_connections:
            validate_arr_connections(token, desired, base_url)
            validate_bazarr_connection(bazarr_key_file)
            validate_seerr_connection(token, desired, base_url)
            verify_seerr_search(token, base_url)
    finally:
        try:
            request("POST", "/Sessions/Logout", token, base_url=base_url)
        except RuntimeError:
            pass


def configure_integrations(entries, username, password_file, profile, desired, bazarr_key_file, backup,
                           base_url="http://127.0.0.1:8096"):
    token, _user = login(username, password_file, base_url)
    changed = False
    original = None
    path = None
    try:
        entry = next(item for item in entries if item["key"] == "JELLYFIN_ENHANCED")
        path = f"/Plugins/{entry['guid']}/Configuration"
        original = request("GET", path, token, base_url=base_url)
        validate_profile_schema(original, profile)
        atomic_json(backup, original)
        if any(original.get(name) != value for name, value in desired.items()):
            updated = dict(original)
            updated.update(desired)
            request("POST", path, token, updated, base_url=base_url)
            changed = True
        actual = request("GET", path, token, base_url=base_url)
        validate_profile_schema(actual, profile)
        if any(actual.get(name) != value for name, value in desired.items()):
            fail("Jellyfin Enhanced profile did not persist")
        validate_arr_connections(token, desired, base_url)
        validate_bazarr_connection(bazarr_key_file)
        validate_seerr_connection(token, desired, base_url)
        verify_seerr_search(token, base_url)
    except Exception:
        if changed and original is not None and path is not None:
            request("POST", path, token, original, base_url=base_url)
        raise
    finally:
        try:
            request("POST", "/Sessions/Logout", token, base_url=base_url)
        except RuntimeError:
            pass


def restore_integrations(entries, username, password_file, profile, backup,
                         base_url="http://127.0.0.1:8096"):
    backup_path = pathlib.Path(backup)
    if not backup_path.is_file() or backup_path.is_symlink() or stat.S_IMODE(backup_path.stat().st_mode) != 0o600:
        fail("protected Jellyfin Enhanced backup is missing or unsafe")
    previous = json.loads(backup_path.read_text(encoding="utf-8"))
    if not isinstance(previous, dict):
        fail("protected Jellyfin Enhanced backup is invalid")
    validate_profile_schema(previous, profile)
    token, _user = login(username, password_file, base_url)
    current = None
    path = None
    try:
        entry = next(item for item in entries if item["key"] == "JELLYFIN_ENHANCED")
        path = f"/Plugins/{entry['guid']}/Configuration"
        current = request("GET", path, token, base_url=base_url)
        validate_profile_schema(current, profile)
        request("POST", path, token, previous, base_url=base_url)
        if request("GET", path, token, base_url=base_url) != previous:
            fail("Jellyfin Enhanced rollback did not persist")
    except Exception:
        if current is not None and path is not None:
            request("POST", path, token, current, base_url=base_url)
        raise
    finally:
        try:
            request("POST", "/Sessions/Logout", token, base_url=base_url)
        except RuntimeError:
            pass


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=("validate-lock", "stage", "snapshot", "configure-live", "verify-live",
                                                "configure-integrations", "verify-integrations", "restore-integrations"))
    parser.add_argument("--lock", required=True)
    parser.add_argument("--output")
    parser.add_argument("--source-dir")
    parser.add_argument("--username")
    parser.add_argument("--password-file")
    parser.add_argument("--baseline")
    parser.add_argument("--base-url", default="http://127.0.0.1:8096")
    parser.add_argument("--expected-version", default="12.3.0")
    parser.add_argument("--sonarr-key-file")
    parser.add_argument("--radarr-key-file")
    parser.add_argument("--bazarr-key-file")
    parser.add_argument("--seerr-key-file")
    parser.add_argument("--tmdb-key-file")
    parser.add_argument("--profile")
    parser.add_argument("--backup")
    args = parser.parse_args()
    entries = parse_lock(args.lock)
    if args.command == "validate-lock":
        return
    if args.command == "stage":
        if not args.output: fail("stage requires --output")
        stage(entries, args.output, args.source_dir)
        return
    if not args.username or not args.password_file:
        fail("live inspection requires credentials")
    if args.command == "restore-integrations":
        if not args.profile or not args.backup:
            fail("integration rollback requires the versioned profile and protected backup")
        restore_integrations(entries, args.username, args.password_file,
                             load_enhanced_profile(args.profile), args.backup, args.base_url)
        return
    if args.command in ("configure-integrations", "verify-integrations"):
        if not all((args.profile, args.sonarr_key_file, args.radarr_key_file,
                    args.bazarr_key_file, args.seerr_key_file, args.tmdb_key_file)):
            fail("integration configuration requires the versioned profile and protected API-key files")
        profile, desired = integration_configuration(args.profile, args.sonarr_key_file, args.radarr_key_file,
                                                      args.seerr_key_file, args.tmdb_key_file)
        if args.command == "configure-integrations":
            if not args.backup:
                fail("integration configuration requires a protected backup path")
            configure_integrations(entries, args.username, args.password_file, profile, desired, args.bazarr_key_file,
                                   args.backup, args.base_url)
        else:
            verify_integrations(entries, args.username, args.password_file, profile, desired, args.bazarr_key_file,
                                args.base_url)
        return
    if args.command == "configure-live":
        configure_live(entries, args.username, args.password_file, args.base_url)
        return
    state = live_state(args.username, args.password_file, entries, args.base_url)
    if args.command == "snapshot":
        if not args.output: fail("snapshot requires --output")
        atomic_json(args.output, state)
    else:
        verify_live(entries, state, args.baseline, args.expected_version)


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, OSError, ValueError, zipfile.BadZipFile, urllib.error.URLError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        raise SystemExit(1)

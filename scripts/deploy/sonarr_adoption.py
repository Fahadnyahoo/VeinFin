#!/usr/bin/env python3
"""Generic, secret-safe Sonarr adoption of an existing series."""

import argparse
import http.cookiejar
import json
import os
import pathlib
import re
import secrets
import shutil
import sqlite3
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

from arr_api import App, field_map, qbit_schema, set_fields
from media_services_api import read_secret, seerr_call, seerr_session


def fail(message):
    raise RuntimeError(message)


def atomic_json(path, value):
    path = pathlib.Path(path)
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    if path.parent.is_symlink() or not path.parent.is_dir():
        fail("protected output directory is unsafe")
    temporary = path.parent / f".{path.name}.{secrets.token_hex(8)}"
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(value, stream, indent=2, sort_keys=True)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.chown(temporary, 0, 0)
        os.replace(temporary, path)
    finally:
        if temporary.exists():
            temporary.unlink()


def protected_json(path):
    path = pathlib.Path(path)
    if not path.is_file() or path.is_symlink() or (path.stat().st_mode & 0o777) != 0o600:
        fail(f"protected runtime file is missing or unsafe: {path.name}")
    return json.loads(path.read_text(encoding="utf-8"))


def snapshot_tree(root):
    root = pathlib.Path(root).resolve()
    if not root.is_dir() or root.is_symlink() or not str(root).startswith("/srv/media/library/anime/"):
        fail("host series path is unavailable or outside the Anime library")
    result = {}
    for path in sorted(root.rglob("*")):
        if path.is_symlink():
            fail("series tree contains a symbolic link")
        if path.is_file():
            stat = path.stat()
            result[path.relative_to(root).as_posix()] = {"size": stat.st_size, "mtime_ns": stat.st_mtime_ns}
    if not result:
        fail("series tree is empty")
    return result


def create_snapshot(args):
    atomic_json(args.snapshot, {"files": snapshot_tree(args.host_series_path)})
    print(f"SNAPSHOT_FILES={len(protected_json(args.snapshot)['files'])}")


def verify_snapshot(args):
    expected = protected_json(args.snapshot).get("files", {})
    actual = snapshot_tree(args.host_series_path)
    if actual != expected:
        fail("media file set, byte size, or timestamp changed")
    return len(actual)


def atomic_bytes(path, data):
    path = pathlib.Path(path)
    temporary = path.parent / f".{path.name}.{secrets.token_hex(8)}"
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.chown(temporary, 0, 0)
        os.replace(temporary, path)
    finally:
        if temporary.exists():
            temporary.unlink()


def create_backup(args):
    source = pathlib.Path(args.config_root, "sonarr")
    database = source / "sonarr.db"
    config = source / "config.xml"
    destination = pathlib.Path(args.backup_dir)
    if destination.exists():
        if destination.is_symlink() or not destination.is_dir() or (destination.stat().st_mode & 0o777) != 0o700:
            fail("existing Sonarr backup directory is unsafe")
        for name in ("sonarr.db", "config.xml", "backup.json"):
            path = destination / name
            if not path.is_file() or path.is_symlink() or (path.stat().st_mode & 0o777) != 0o600:
                fail("existing Sonarr backup is incomplete or unsafe")
        print("BACKUP=PRESERVED")
        return
    if not database.is_file() or database.is_symlink() or not config.is_file() or config.is_symlink():
        fail("Sonarr database or configuration is unavailable")
    destination.mkdir(mode=0o700, parents=True)
    os.chown(destination, 0, 0)
    try:
        output = destination / ".sonarr.db.tmp"
        source_db = sqlite3.connect(f"file:{database}?mode=ro", uri=True)
        target_db = sqlite3.connect(output)
        try:
            source_db.backup(target_db)
            target_db.commit()
        finally:
            target_db.close()
            source_db.close()
        os.chmod(output, 0o600)
        os.chown(output, 0, 0)
        os.replace(output, destination / "sonarr.db")
        atomic_bytes(destination / "config.xml", config.read_bytes())
        atomic_json(destination / "backup.json", {"database": "sonarr.db", "configuration": "config.xml", "consistent_sqlite_backup": True})
    except Exception:
        for path in destination.iterdir():
            if path.is_file() and not path.is_symlink():
                path.unlink()
        destination.rmdir()
        raise
    print("BACKUP=CREATED")


def key(path):
    return read_secret(pathlib.Path(path))


def sonarr_delete(app, series_id):
    request = urllib.request.Request(
        f"{app.base}/series/{series_id}?deleteFiles=false&addImportListExclusion=false",
        method="DELETE", headers={"X-Api-Key": app.api_key},
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            if response.status not in (200, 202, 204):
                fail("Sonarr rollback delete was rejected")
    except urllib.error.HTTPError as error:
        fail(f"Sonarr rollback delete failed (HTTP {error.code})")


def qbit_torrent_count(username, password):
    jar = http.cookiejar.CookieJar()
    opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))
    body = urllib.parse.urlencode({"username": username, "password": password}).encode()
    headers = {"Referer": "http://127.0.0.1:8080"}
    opener.open(urllib.request.Request("http://127.0.0.1:8080/api/v2/auth/login", data=body, headers=headers), timeout=15).read()
    request = urllib.request.Request("http://127.0.0.1:8080/api/v2/torrents/info", headers=headers)
    return len(json.load(opener.open(request, timeout=15)))


def verify_download_contract(sonarr, username, password):
    tags = [tag for tag in sonarr.get("tag") if tag.get("label") == "anime"]
    if len(tags) != 1:
        fail("Sonarr Anime tag is missing or ambiguous")
    expected = {"VeinFin qBittorrent TV": "tv", "VeinFin qBittorrent Anime": "anime"}
    clients = sonarr.get("downloadclient")
    if {item.get("name") for item in clients} != set(expected):
        fail("Sonarr download-client set changed")
    for client in clients:
        fields = {name: field.get("value") for name, field in field_map(client).items()}
        category = expected[client["name"]]
        expected_tags = [tags[0]["id"]] if category == "anime" else []
        if (fields.get("host"), int(fields.get("port", 0)), fields.get("tvCategory"), client.get("tags")) != ("qbittorrent", 8080, category, expected_tags):
            fail("Sonarr qBittorrent routing contract changed")
        resource = qbit_schema(sonarr)
        resource.update(name=client["name"], enable=True, priority=client.get("priority", 1), tags=expected_tags,
                        removeCompletedDownloads=True, removeFailedDownloads=True, id=client["id"])
        set_fields(resource, {"host": "qbittorrent", "port": 8080, "useSsl": False, "urlBase": "",
                              "username": username, "password": password, "tvCategory": category,
                              "tvImportedCategory": ""}, {"host", "port", "useSsl", "username", "password", "tvCategory"})
        sonarr.post("downloadclient/test", resource)
    if not sonarr.get("config/downloadclient").get("enableCompletedDownloadHandling"):
        fail("Completed Download Handling is disabled")
    if not sonarr.get("config/mediamanagement").get("copyUsingHardlinks"):
        fail("hardlink imports are disabled")
    if sonarr.get("config/naming").get("renameEpisodes"):
        fail("episode renaming is enabled")
    return tags[0]["id"]


def expected_lookup(sonarr, args):
    results = sonarr.get("series/lookup?term=" + urllib.parse.quote(args.lookup_term, safe=""))
    matches = [item for item in results if int(item.get("tvdbId", 0)) == args.expected_tvdb_id]
    if len(matches) != 1:
        fail("Sonarr lookup did not resolve exactly one expected identity")
    return matches[0]


def quality_profile(sonarr, name):
    matches = [item for item in sonarr.get("qualityprofile") if item.get("name") == name]
    if len(matches) != 1:
        fail("selected existing quality profile is missing or ambiguous")
    return matches[0]


def common_state(args):
    password = key(args.password_file)
    sonarr = App("sonarr", key(args.sonarr_key_file))
    radarr = App("radarr", key(args.radarr_key_file))
    prowlarr = App("prowlarr", key(args.prowlarr_key_file))
    tag_id = verify_download_contract(sonarr, args.username, password)
    if sonarr.get("indexer") or sonarr.get("remotepathmapping"):
        fail("Sonarr contains an indexer or remote path mapping")
    if radarr.get("movie"):
        fail("Radarr is not empty")
    if prowlarr.get("indexer"):
        fail("Prowlarr contains an indexer")
    if qbit_torrent_count(args.username, password) != 0:
        fail("qBittorrent contains a torrent")
    seerr = seerr_session(args.username, password, False)
    requests = seerr_call(seerr, "GET", "request?take=1&skip=0")
    if int(requests.get("pageInfo", {}).get("results", -1)) != 0:
        fail("Seerr contains a request")
    lookup = expected_lookup(sonarr, args)
    profile = quality_profile(sonarr, args.quality_profile)
    roots = [item for item in sonarr.get("rootfolder") if item.get("path", "").rstrip("/") == "/data/library/anime"]
    if len(roots) != 1:
        fail("Sonarr Anime root folder is missing or ambiguous")
    return sonarr, tag_id, lookup, profile


def active_search_commands(sonarr):
    commands = sonarr.get("command")
    return [item for item in commands if re.search(r"search|rss", str(item.get("name", "")), re.I)
            and str(item.get("status", "")).lower() not in ("completed", "failed", "aborted")]


def wait_command(sonarr, command_id):
    deadline = time.monotonic() + 1800
    while time.monotonic() < deadline:
        command = sonarr.get(f"command/{command_id}")
        status = str(command.get("status", "")).lower()
        if status == "completed":
            return command
        if status in ("failed", "aborted"):
            fail("Sonarr local disk rescan did not complete successfully")
        time.sleep(2)
    fail("Sonarr local disk rescan timed out")


def wait_new_refresh(sonarr, previous_ids, series_id):
    deadline = time.monotonic() + 120
    while time.monotonic() < deadline:
        for command in sonarr.get("command"):
            if command.get("id") in previous_ids or command.get("name") != "RefreshSeries":
                continue
            body = command.get("body") or {}
            if body.get("seriesId") is not None and int(body["seriesId"]) != series_id:
                continue
            return wait_command(sonarr, command["id"])
        time.sleep(1)
    fail("Sonarr automatic RefreshSeries command was not observed")


def wait_series_commands_idle(sonarr, series_id):
    deadline = time.monotonic() + 1800
    while time.monotonic() < deadline:
        active = []
        for command in sonarr.get("command"):
            body = command.get("body") or {}
            related = body.get("seriesId") is not None and int(body["seriesId"]) == series_id
            if not related and command.get("name") not in ("RefreshSeries", "RescanSeries"):
                continue
            if str(command.get("status", "")).lower() not in ("completed", "failed", "aborted"):
                active.append(command)
        if not active:
            return
        time.sleep(2)
    fail("Sonarr series refresh/rescan did not become idle")


def wait_file_count_stable(sonarr, series_id, expected):
    deadline = time.monotonic() + 300
    stable = 0
    observations = []
    while time.monotonic() < deadline:
        count = len(sonarr.get(f"episodefile?seriesId={series_id}"))
        observations.append(count)
        stable = stable + 1 if count == expected else 0
        if stable >= 6:
            return count, observations[-6:]
        time.sleep(2)
    fail(f"Sonarr episode-file count did not stabilize at {expected}; last observed {observations[-1] if observations else 'none'}")


def verify_series(sonarr, args, profile, tag_id):
    matching = [item for item in sonarr.get("series") if int(item.get("tvdbId", 0)) == args.expected_tvdb_id]
    if len(matching) != 1 or len(sonarr.get("series")) != 1:
        fail("Sonarr series set is not exactly the adopted identity")
    series = matching[0]
    if (series.get("path"), series.get("rootFolderPath"), series.get("seriesType"), bool(series.get("monitored")),
        int(series.get("qualityProfileId", 0)), series.get("tags")) != (
        args.series_path, "/data/library/anime", "anime", False, int(profile["id"]), [tag_id]):
        fail("adopted Sonarr series settings differ from the safe contract")
    episodes = sonarr.get(f"episode?seriesId={series['id']}")
    files = sonarr.get(f"episodefile?seriesId={series['id']}")
    if any(episode.get("monitored") for episode in episodes):
        fail("one or more Sonarr episodes are monitored")
    if len(files) != args.expected_files:
        fail("Sonarr did not recognize the expected episode-file count")
    file_ids = {int(item.get("id", 0)) for item in files}
    recognized = [episode for episode in episodes if int(episode.get("episodeFileId", 0)) in file_ids]
    if len(recognized) != args.expected_files:
        fail("Sonarr episode-to-file mapping is incomplete or duplicated")
    numbers = []
    for episode in recognized:
        value = episode.get("sceneAbsoluteEpisodeNumber") or episode.get("absoluteEpisodeNumber")
        if value is None:
            fail("Sonarr omitted an absolute episode number")
        numbers.append(int(value))
    if sorted(numbers) != list(range(1, args.expected_files + 1)) or len(set(numbers)) != args.expected_files:
        fail("Sonarr absolute episode mapping is not exactly contiguous")
    base = pathlib.PurePosixPath(args.series_path)
    for item in files:
        path = pathlib.PurePosixPath(item.get("path") or str(base / item.get("relativePath", "")))
        try:
            path.relative_to(base)
        except ValueError:
            fail("Sonarr recognized an episode file outside the existing series directory")
    if active_search_commands(sonarr):
        fail("an automatic/RSS search command is active")
    return series, len(episodes), len(files)


def report(args, lookup, profile, series, episode_records, files, media_files, execution=None):
    value = {
        "identity": {"title": lookup.get("title"), "year": lookup.get("year"), "tvdb_id": lookup.get("tvdbId")},
        "quality_profile": {"id": profile.get("id"), "name": profile.get("name")},
        "sonarr": {"series_id": series.get("id"), "series_type": series.get("seriesType"), "monitored": series.get("monitored"),
                   "episode_records": episode_records, "episode_files": files, "path": series.get("path")},
        "media_snapshot_files": media_files,
        "qbit_torrents": 0, "search_for_missing": False, "automatic_search": False,
    }
    if execution is not None:
        value.update(execution)
    elif pathlib.Path(args.report).exists():
        old = protected_json(args.report)
        for name in ("command_timeline", "stable_file_counts"):
            if name in old:
                value[name] = old[name]
    atomic_json(args.report, value)
    print("SONARR_SUMMARY=" + json.dumps(value, sort_keys=True))


def check_mode(args, write_report=False):
    sonarr, tag_id, lookup, profile = common_state(args)
    series = sonarr.get("series")
    if args.expected_state == "empty":
        if series:
            fail("Sonarr is not empty before adoption")
        print(f"CHECK=EMPTY TVDB_ID={lookup.get('tvdbId')} QUALITY_PROFILE={profile.get('name')}")
    else:
        adopted, episode_records, files = verify_series(sonarr, args, profile, tag_id)
        media_files = verify_snapshot(args)
        if write_report:
            report(args, lookup, profile, adopted, episode_records, files, media_files)
        else:
            print(f"CHECK=ADOPTED TVDB_ID={lookup.get('tvdbId')} EPISODE_FILES={files}")


def apply_mode(args):
    sonarr, tag_id, lookup, profile = common_state(args)
    if sonarr.get("series"):
        fail("Sonarr must be empty before first adoption")
    if active_search_commands(sonarr):
        fail("a search command is active before adoption")
    resource = dict(lookup)
    resource.update(rootFolderPath="/data/library/anime", path=args.series_path,
                    qualityProfileId=profile["id"], seriesType="anime", monitored=False,
                    seasonFolder=False, tags=[tag_id],
                    addOptions={"monitor": "none", "searchForMissingEpisodes": False,
                                "searchForCutoffUnmetEpisodes": False})
    created = None
    previous_commands = {item.get("id") for item in sonarr.get("command")}
    try:
        created = sonarr.post("series", resource)
        # Adding a series starts RefreshSeries itself. Require observing that
        # new command and its completion before requesting the local rescan.
        refresh = wait_new_refresh(sonarr, previous_commands, created["id"])
        wait_series_commands_idle(sonarr, created["id"])
        command = sonarr.post("command", {"name": "RescanSeries", "seriesId": created["id"]})
        rescan = wait_command(sonarr, command["id"])
        wait_series_commands_idle(sonarr, created["id"])
        observed_files, observations = wait_file_count_stable(sonarr, created["id"], args.expected_files)
        if observed_files != args.expected_files:
            fail(f"Sonarr recognized {observed_files} episode files; expected {args.expected_files}")
        new_commands = [item for item in sonarr.get("command") if item.get("id") not in previous_commands]
        if any(re.search(r"search|rss", str(item.get("name", "")), re.I) for item in new_commands):
            fail("a search or RSS command occurred during adoption")
        adopted, episode_records, files = verify_series(sonarr, args, profile, tag_id)
        media_files = verify_snapshot(args)
        if qbit_torrent_count(args.username, key(args.password_file)) != 0:
            fail("qBittorrent changed during adoption")
        timeline = [{"id": item.get("id"), "name": item.get("name"), "started": item.get("started"),
                     "ended": item.get("ended"), "status": item.get("status")} for item in (refresh, rescan)]
        report(args, lookup, profile, adopted, episode_records, files, media_files,
               {"command_timeline": timeline, "stable_file_counts": observations})
    except Exception:
        if created is not None:
            sonarr_delete(sonarr, created["id"])
            if sonarr.get("series"):
                fail("adoption failed and Sonarr API rollback did not restore an empty series set")
        verify_snapshot(args)
        raise


def add_common(parser):
    parser.add_argument("--username", required=True)
    parser.add_argument("--password-file", required=True)
    parser.add_argument("--sonarr-key-file", required=True)
    parser.add_argument("--radarr-key-file", required=True)
    parser.add_argument("--prowlarr-key-file", required=True)
    parser.add_argument("--lookup-term", required=True)
    parser.add_argument("--expected-tvdb-id", required=True, type=int)
    parser.add_argument("--quality-profile", required=True)
    parser.add_argument("--series-path", required=True)
    parser.add_argument("--host-series-path", required=True)
    parser.add_argument("--expected-files", required=True, type=int)
    parser.add_argument("--snapshot", required=True)
    parser.add_argument("--report", required=True)


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="mode", required=True)
    snapshot = sub.add_parser("snapshot")
    snapshot.add_argument("--host-series-path", required=True)
    snapshot.add_argument("--snapshot", required=True)
    backup = sub.add_parser("backup")
    backup.add_argument("--config-root", required=True)
    backup.add_argument("--backup-dir", required=True)
    check = sub.add_parser("check")
    add_common(check)
    check.add_argument("--expected-state", choices=("empty", "adopted"), required=True)
    apply = sub.add_parser("apply")
    add_common(apply)
    verify = sub.add_parser("verify")
    add_common(verify)
    args = parser.parse_args()
    if args.mode == "snapshot":
        create_snapshot(args)
    elif args.mode == "backup":
        create_backup(args)
    elif args.mode == "apply":
        apply_mode(args)
    else:
        args.expected_state = "adopted" if args.mode == "verify" else args.expected_state
        check_mode(args, write_report=args.mode == "verify")


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"ERROR: {error}", file=sys.stderr)
        sys.exit(1)

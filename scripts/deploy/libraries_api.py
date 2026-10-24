#!/usr/bin/env python3
"""Runtime-only media probing and Jellyfin library reconciliation for Library setup."""

import argparse
import collections
import datetime
import json
import os
import pathlib
import re
import secrets
import subprocess
import sys
import time
import urllib.parse

from media_services_api import jellyfin_login, read_secret, request

BASE = "http://127.0.0.1:8096"
LIBRARIES = {
    "Movies": ("movies", "/data/library/movies"),
    "TV Shows": ("tvshows", "/data/library/tv"),
    "Anime": ("tvshows", "/data/library/anime"),
}


def fail(message):
    raise RuntimeError(message)


def atomic_json(path, value):
    path = pathlib.Path(path)
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(path.parent, 0o700)
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


def load_json(path):
    path = pathlib.Path(path)
    if not path.is_file() or path.is_symlink() or (path.stat().st_mode & 0o777) != 0o600:
        fail("runtime report is missing or unsafe")
    return json.loads(path.read_text(encoding="utf-8"))


def run(command, timeout=90):
    return subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=timeout, check=False)


def episode_number(path, pattern):
    matches = pattern.findall(path.name)
    if len(matches) != 1:
        return None
    value = matches[0]
    if isinstance(value, tuple):
        value = next((item for item in value if item), "")
    return int(value)


def probe_media(args):
    host = pathlib.Path(args.host_media_path).resolve()
    if not host.is_dir() or host.is_symlink():
        fail("media path must be a real directory")
    if not str(host).startswith("/srv/media/library/anime/"):
        fail("media path is outside the Anime destination")
    container = pathlib.PurePosixPath(args.container_media_path)
    if not str(container).startswith("/data/library/anime/"):
        fail("container media path is outside the Anime library")
    pattern = re.compile(args.episode_pattern)
    all_files = sorted(path for path in host.rglob("*") if path.is_file() and not path.is_symlink())
    mkvs = [path for path in all_files if path.suffix.lower() == ".mkv"]
    numbers = [episode_number(path, pattern) for path in mkvs]
    expected_numbers = list(range(1, args.expected_count + 1))
    exact_inventory = (
        len(mkvs) == args.expected_count
        and all(path.stat().st_size > 0 for path in mkvs)
        and None not in numbers
        and sorted(numbers) == expected_numbers
        and len(set(numbers)) == args.expected_count
    )

    categories = {
        "external_subtitles": {".srt", ".ass", ".ssa", ".vtt", ".sub", ".idx", ".sup"},
        "fonts": {".ttf", ".otf", ".woff", ".woff2"},
        "images": {".jpg", ".jpeg", ".png", ".webp", ".gif", ".avif"},
        "chapters": {".chapters", ".cue"},
        "metadata": {".nfo", ".json", ".xml", ".yaml", ".yml"},
    }
    sidecars = {name: sum(path.suffix.lower() in suffixes for path in all_files) for name, suffixes in categories.items()}
    audio_languages = collections.Counter()
    subtitle_languages = collections.Counter()
    subtitle_formats = collections.Counter()
    video_files = audio_files = subtitle_files = probe_errors = 0
    paths_by_number = {}

    for index, path in enumerate(mkvs, 1):
        relative = path.relative_to(host)
        container_path = str(container / pathlib.PurePosixPath(relative.as_posix()))
        number = episode_number(path, pattern)
        if number is not None:
            paths_by_number[str(number)] = container_path
        result = run([
            "docker", "exec", "veinfin-jellyfin-1", "/usr/lib/jellyfin-ffmpeg/ffprobe",
            "-v", "error", "-show_entries", "stream=codec_type,codec_name:stream_tags=language",
            "-of", "json", container_path,
        ])
        if result.returncode != 0:
            probe_errors += 1
            continue
        try:
            streams = json.loads(result.stdout).get("streams", [])
        except json.JSONDecodeError:
            probe_errors += 1
            continue
        video = [stream for stream in streams if stream.get("codec_type") == "video"]
        audio = [stream for stream in streams if stream.get("codec_type") == "audio"]
        subtitles = [stream for stream in streams if stream.get("codec_type") == "subtitle"]
        video_files += bool(video)
        audio_files += bool(audio)
        subtitle_files += bool(subtitles)
        for stream in audio:
            audio_languages[(stream.get("tags") or {}).get("language", "und").lower()] += 1
        for stream in subtitles:
            subtitle_languages[(stream.get("tags") or {}).get("language", "und").lower()] += 1
            subtitle_formats[stream.get("codec_name", "unknown").lower()] += 1
        if index % 25 == 0:
            print(f"INFO: probed {index}/{len(mkvs)} MKV containers", flush=True)

    sample_numbers = [1, (args.expected_count + 1) // 2, args.expected_count]
    decode = {}
    for number in sample_numbers:
        path = paths_by_number.get(str(number))
        if not path:
            decode[str(number)] = False
            continue
        result = run([
            "docker", "exec", "veinfin-jellyfin-1", "/usr/lib/jellyfin-ffmpeg/ffmpeg",
            "-nostdin", "-v", "error", "-i", path, "-t", "3",
            "-map", "0:v:0", "-map", "0:a:0?", "-f", "null", "-",
        ], timeout=180)
        decode[str(number)] = result.returncode == 0

    report = {
        "generated_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "inventory": {
            "mkv_files": len(mkvs),
            "unique_episode_numbers": len(set(number for number in numbers if number is not None)),
            "nonempty_mkv_files": sum(path.stat().st_size > 0 for path in mkvs),
            "exact_inventory": exact_inventory,
            "sidecars": sidecars,
        },
        "probe": {
            "video_files": video_files,
            "audio_files": audio_files,
            "audio_languages": dict(sorted(audio_languages.items())),
            "embedded_subtitle_files": subtitle_files,
            "embedded_subtitle_languages": dict(sorted(subtitle_languages.items())),
            "embedded_subtitle_formats": dict(sorted(subtitle_formats.items())),
            "external_subtitle_files": sidecars["external_subtitles"],
            "probe_errors": probe_errors,
        },
        "decode_samples": decode,
        "episode_container_paths": paths_by_number,
    }
    atomic_json(args.report, report)
    print("SUMMARY: " + json.dumps({**report["inventory"], **report["probe"], "decode_samples": decode}, sort_keys=True))
    if not exact_inventory:
        fail("media inventory is not exactly the expected contiguous episode range")
    if probe_errors or video_files != args.expected_count or audio_files != args.expected_count:
        fail("one or more MKV containers failed required stream validation")
    if not all(decode.values()):
        fail("first, middle, or final decode sample failed")


def auth(username, password_file):
    password = read_secret(pathlib.Path(password_file))
    token = jellyfin_login(username, password)
    headers = {"Authorization": f'MediaBrowser Client="VeinFin", Device="libraries", DeviceId="libraries", Version="1.0", Token="{token}"'}
    users = request("GET", BASE + "/Users", headers=headers)
    admins = [user for user in users if user.get("Policy", {}).get("IsAdministrator")]
    if len(users) != 1 or len(admins) != 1 or admins[0].get("Name") != username:
        fail("Jellyfin administrator contract changed")
    return headers, admins[0]["Id"]


def api(headers, method, path, query=None, body=None):
    url = BASE + path
    if query:
        url += "?" + urllib.parse.urlencode(query, doseq=True)
    return request(method, url, body=body, headers=headers)


def verify_locale(headers, language, country):
    config = api(headers, "GET", "/System/Configuration")
    if config.get("PreferredMetadataLanguage") != language or config.get("MetadataCountryCode") != country:
        fail("Jellyfin metadata language or country changed")


def folder_map(headers):
    folders = api(headers, "GET", "/Library/VirtualFolders")
    result = {}
    for folder in folders:
        name = folder.get("Name")
        if name in result:
            fail("duplicate Jellyfin library name")
        result[name] = folder
    return result


def reconcile_libraries(headers):
    current = folder_map(headers)
    if set(current) - set(LIBRARIES):
        fail("an unexpected Jellyfin library exists")
    for name, (collection_type, path) in LIBRARIES.items():
        if name in current:
            folder = current[name]
            if folder.get("CollectionType") != collection_type or folder.get("Locations") != [path]:
                fail(f"existing {name} library contract differs")
            continue
        api(headers, "POST", "/Library/VirtualFolders", {
            "name": name, "collectionType": collection_type, "paths": [path], "refreshLibrary": "false",
        }, {})
    current = folder_map(headers)
    if set(current) != set(LIBRARIES):
        fail("exact Jellyfin library set was not created")
    for name, (collection_type, path) in LIBRARIES.items():
        if current[name].get("CollectionType") != collection_type or current[name].get("Locations") != [path]:
            fail(f"{name} library is not exact")


def scan_task(headers):
    tasks = api(headers, "GET", "/ScheduledTasks")
    matches = [task for task in tasks if task.get("Key") == "RefreshLibrary"]
    if len(matches) != 1:
        fail("Jellyfin library scan task is missing or duplicated")
    return matches[0]


def run_scan(headers):
    before = scan_task(headers).get("LastExecutionResult", {}).get("EndTimeUtc")
    api(headers, "POST", "/Library/Refresh")
    deadline = time.monotonic() + 7200
    last_notice = 0
    while time.monotonic() < deadline:
        task = scan_task(headers)
        result = task.get("LastExecutionResult") or {}
        if task.get("State") == "Idle" and result.get("EndTimeUtc") != before:
            if result.get("Status") not in (None, "Completed"):
                fail("Jellyfin library scan completed unsuccessfully")
            return
        if time.monotonic() - last_notice > 30:
            print("INFO: Jellyfin library scan is active", flush=True)
            last_notice = time.monotonic()
        time.sleep(3)
    fail("Jellyfin library scan did not complete within two hours")


def items(headers, user_id, parent_id, types, fields="Path,MediaSources,ProviderIds,SpecialEpisodeNumbers"):
    return api(headers, "GET", "/Items", {
        "userId": user_id, "parentId": parent_id, "recursive": "true",
        "includeItemTypes": types, "fields": fields, "enableTotalRecordCount": "true", "limit": 10000,
    }).get("Items", [])


def expected_playback_mode(source):
    if source.get("SupportsDirectPlay"):
        return "Direct Play"
    if source.get("SupportsDirectStream"):
        return "Remux"
    if source.get("SupportsTranscoding"):
        return "Transcode"
    return "Unsupported"


def verify_jellyfin(args, headers, user_id, report):
    folders = folder_map(headers)
    if set(folders) != set(LIBRARIES):
        fail("Jellyfin library set is not exact")
    for name, (kind, path) in LIBRARIES.items():
        folder = folders[name]
        if folder.get("CollectionType") != kind or folder.get("Locations") != [path]:
            fail(f"{name} library path or type is incorrect")
    movies = items(headers, user_id, folders["Movies"]["ItemId"], "Movie")
    television = items(headers, user_id, folders["TV Shows"]["ItemId"], "Series,Season,Episode")
    anime_id = folders["Anime"]["ItemId"]
    series = items(headers, user_id, anime_id, "Series")
    seasons = items(headers, user_id, anime_id, "Season")
    episodes = items(headers, user_id, anime_id, "Episode")
    expected_paths = set(report["episode_container_paths"].values())
    actual_paths = {episode.get("Path") for episode in episodes}
    keys = [(episode.get("ParentIndexNumber"), episode.get("IndexNumber")) for episode in episodes]
    recognized_numbers = {episode.get("IndexNumber") for episode in episodes}
    recognized_seasons = {episode.get("ParentIndexNumber") for episode in episodes}
    naming_ok = (
        len(series) == 1 and series[0].get("Name", "").casefold() == args.expected_series_name.casefold()
        and len(seasons) == 1 and len(episodes) == args.expected_count and actual_paths == expected_paths
        and None not in actual_paths and len(set(keys)) == args.expected_count
        and recognized_numbers == set(range(1, args.expected_count + 1)) and recognized_seasons == {1}
        and all(episode.get("Name") and episode.get("MediaSources") for episode in episodes)
    )
    if movies or television:
        fail("Movies or TV Shows library is not empty")
    season_counts = collections.Counter(str(episode.get("ParentIndexNumber")) for episode in episodes)
    playback = {}
    by_path = {episode.get("Path"): episode for episode in episodes}
    for number in (1, (args.expected_count + 1) // 2, args.expected_count):
        path = report["episode_container_paths"].get(str(number))
        episode = by_path.get(path)
        if not episode:
            playback[str(number)] = "Missing"
            continue
        result = api(headers, "POST", f"/Items/{episode['Id']}/PlaybackInfo", body={
            "UserId": user_id, "EnableDirectPlay": True, "EnableDirectStream": True,
            "EnableTranscoding": True, "AllowVideoStreamCopy": True, "AllowAudioStreamCopy": True,
        })
        sources = result.get("MediaSources") or []
        playback[str(number)] = expected_playback_mode(sources[0]) if sources else "Unsupported"
    report["jellyfin"] = {
        "libraries": {name: {"type": kind, "path": path} for name, (kind, path) in LIBRARIES.items()},
        "movies": len(movies), "tv_items": len(television), "series": len(series),
        "seasons": len(seasons), "episodes": len(episodes),
        "season_episode_counts": dict(sorted(season_counts.items())),
        "naming_ok": naming_ok, "playback_samples": playback,
        "scan_state": scan_task(headers).get("State"),
    }
    atomic_json(args.report, report)
    print("JELLYFIN_SUMMARY: " + json.dumps(report["jellyfin"], sort_keys=True))
    if not naming_ok:
        fail("Jellyfin naming recognition is not the expected one-series contiguous result")
    if any(mode == "Missing" or mode == "Unsupported" for mode in playback.values()):
        fail("Jellyfin playback information is invalid for a sample episode")
    if report["jellyfin"]["scan_state"] != "Idle":
        fail("Jellyfin library scan remains active")


def jellyfin_mode(args):
    report = load_json(args.report)
    headers, user_id = auth(args.username, args.password_file)
    verify_locale(headers, args.language, args.country)
    if args.mode == "apply":
        reconcile_libraries(headers)
        run_scan(headers)
    verify_jellyfin(args, headers, user_id, report)


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="mode", required=True)
    probe = sub.add_parser("probe")
    probe.add_argument("--host-media-path", required=True)
    probe.add_argument("--container-media-path", required=True)
    probe.add_argument("--episode-pattern", required=True)
    probe.add_argument("--expected-count", required=True, type=int)
    probe.add_argument("--report", required=True)
    for mode in ("apply", "verify"):
        command = sub.add_parser(mode)
        command.add_argument("--username", required=True)
        command.add_argument("--password-file", required=True)
        command.add_argument("--expected-series-name", required=True)
        command.add_argument("--expected-count", required=True, type=int)
        command.add_argument("--language", required=True)
        command.add_argument("--country", required=True)
        command.add_argument("--report", required=True)
    args = parser.parse_args()
    if args.mode == "probe":
        probe_media(args)
    else:
        jellyfin_mode(args)


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"ERROR: {error}", file=sys.stderr)
        sys.exit(1)

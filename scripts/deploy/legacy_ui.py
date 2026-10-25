#!/usr/bin/env python3
"""Bootstrap and inspect the isolated Jellyfin 10.11 legacy-UI candidate."""

import argparse
import json
import os
import pathlib
import secrets
import stat
import time
import urllib.error
import urllib.parse
import urllib.request

LIBRARIES = {
    "Movies": ("movies", "/data/library/movies"),
    "TV Shows": ("tvshows", "/data/library/tv"),
    "Anime": ("tvshows", "/data/library/anime"),
}
DEVICE_ID = f"veinfin_legacy_candidate_{os.getpid()}_{secrets.token_hex(4)}"


def fail(message):
    raise RuntimeError(message)


def secret(path):
    value = pathlib.Path(path)
    if not value.is_file() or value.is_symlink() or stat.S_IMODE(value.stat().st_mode) != 0o600:
        fail("candidate credential file is missing or unsafe")
    result = value.read_text(encoding="utf-8").rstrip("\r\n")
    if not result:
        fail("candidate credential is empty")
    return result


def request(base, method, path, token=None, body=None, query=None):
    url = base.rstrip("/") + path
    if query:
        url += "?" + urllib.parse.urlencode(query, doseq=True)
    auth = f'MediaBrowser Client="VeinFin", Device="legacy-candidate", DeviceId="{DEVICE_ID}", Version="1.0"'
    if token:
        auth += f', Token="{token}"'
    headers = {"Authorization": auth}
    data = None
    if body is not None:
        data = json.dumps(body, separators=(",", ":")).encode()
        headers["Content-Type"] = "application/json"
    try:
        with urllib.request.urlopen(urllib.request.Request(url, data=data, method=method, headers=headers), timeout=45) as response:
            raw = response.read()
            return json.loads(raw) if raw else None
    except urllib.error.HTTPError as error:
        fail(f"candidate API {path} returned HTTP {error.code}")


def login(args):
    result = request(args.base_url, "POST", "/Users/AuthenticateByName", body={
        "Username": args.username, "Pw": secret(args.password_file),
    })
    token = result.get("AccessToken", "")
    user = result.get("User") or {}
    if not token or not user.get("Policy", {}).get("IsAdministrator"):
        fail("candidate administrator authentication failed")
    return token, user


def logout(args, token):
    try:
        request(args.base_url, "POST", "/Sessions/Logout", token)
    except RuntimeError:
        pass


def atomic_json(path, value):
    target = pathlib.Path(path)
    target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(target.parent, 0o700)
    temporary = target.parent / f".{target.name}.{secrets.token_hex(8)}"
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(value, stream, sort_keys=True, separators=(",", ":"))
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, target)
    finally:
        if temporary.exists():
            temporary.unlink()


def bootstrap(args):
    public = request(args.base_url, "GET", "/System/Info/Public")
    if not public.get("StartupWizardCompleted"):
        request(args.base_url, "POST", "/Startup/Configuration", body={
            "ServerName": "VeinFin Legacy Candidate", "UICulture": "en-US",
            "MetadataCountryCode": "US", "PreferredMetadataLanguage": "en",
        })
        request(args.base_url, "GET", "/Startup/User")
        request(args.base_url, "POST", "/Startup/User", body={
            "Name": args.username, "Password": secret(args.password_file),
        })
        request(args.base_url, "POST", "/Startup/RemoteAccess", body={
            "EnableRemoteAccess": False, "EnableAutomaticPortMapping": False,
        })
        request(args.base_url, "POST", "/Startup/Complete", body={})
    token, user = login(args)
    try:
        users = request(args.base_url, "GET", "/Users", token)
        if len(users) != 1 or user.get("Name") != args.username:
            fail("candidate does not contain exactly the required administrator")
    finally:
        logout(args, token)


def folders(args, token):
    values = request(args.base_url, "GET", "/Library/VirtualFolders", token)
    return {entry.get("Name"): entry for entry in values}


def reconcile_libraries(args, token):
    current = folders(args, token)
    if set(current) - set(LIBRARIES):
        fail("candidate contains an unexpected library")
    for name, (kind, path) in LIBRARIES.items():
        if name not in current:
            request(args.base_url, "POST", "/Library/VirtualFolders", token, body={}, query={
                "name": name, "collectionType": kind, "paths": [path], "refreshLibrary": "false",
            })
    current = folders(args, token)
    for name, (kind, path) in LIBRARIES.items():
        folder = current.get(name) or {}
        if folder.get("CollectionType") != kind or folder.get("Locations") != [path]:
            fail(f"candidate {name} library contract is incorrect")


def scan(args, token):
    tasks = request(args.base_url, "GET", "/ScheduledTasks", token)
    task = next((item for item in tasks if item.get("Key") == "RefreshLibrary"), None)
    if not task:
        fail("candidate library refresh task is unavailable")
    before = (task.get("LastExecutionResult") or {}).get("EndTimeUtc")
    request(args.base_url, "POST", "/Library/Refresh", token)
    deadline = time.monotonic() + args.scan_timeout
    while time.monotonic() < deadline:
        tasks = request(args.base_url, "GET", "/ScheduledTasks", token)
        task = next(item for item in tasks if item.get("Key") == "RefreshLibrary")
        result = task.get("LastExecutionResult") or {}
        if task.get("State") == "Idle" and result.get("EndTimeUtc") != before:
            if result.get("Status") not in (None, "Completed"):
                fail("candidate library scan failed")
            return
        time.sleep(3)
    fail("candidate library scan timed out")


def collect(args, token, user):
    info = request(args.base_url, "GET", "/System/Info", token)
    installed = request(args.base_url, "GET", "/Plugins", token)
    users = request(args.base_url, "GET", "/Users", token)
    library_map = folders(args, token)
    items = request(args.base_url, "GET", f"/Users/{user['Id']}/Items", token, query={
        "Recursive": "true", "Fields": "Path,MediaSources,UserData",
        "IncludeItemTypes": "Series,Season,Episode,Movie", "Limit": 10000,
    }).get("Items", [])
    counts = {}
    paths = []
    for item in items:
        kind = item.get("Type", "Unknown")
        counts[kind] = counts.get(kind, 0) + 1
        if kind == "Episode":
            paths.append(item.get("Path"))
    return {
        "version": info.get("Version"), "users": len(users),
        "libraries": {name: {"type": entry.get("CollectionType"), "locations": entry.get("Locations")} for name, entry in sorted(library_map.items())},
        "counts": counts, "episode_paths_inside_anime": all(isinstance(path, str) and path.startswith("/data/library/anime/") for path in paths),
        "plugins": sorted(({"id": p.get("Id"), "name": p.get("Name"), "version": p.get("Version"), "status": p.get("Status")} for p in installed), key=lambda p: p["name"] or ""),
    }


def libraries(args):
    token, user = login(args)
    try:
        reconcile_libraries(args, token)
        if args.scan:
            scan(args, token)
        state = collect(args, token, user)
        if args.scan and (state["counts"].get("Episode") != 170 or state["counts"].get("Series") != 1 or state["counts"].get("Season") != 1):
            fail("candidate did not recognize the protected 170-episode library")
        if not state["episode_paths_inside_anime"]:
            fail("candidate recognized an episode outside the Anime library")
        atomic_json(args.output, state)
    finally:
        logout(args, token)


def snapshot(args):
    token, user = login(args)
    try:
        atomic_json(args.output, collect(args, token, user))
    finally:
        logout(args, token)


def plugin_configs(args):
    token, _user = login(args)
    try:
        values = {}
        for guid in args.guid:
            values[guid] = request(args.base_url, "GET", f"/Plugins/{guid}/Configuration", token)
        atomic_json(args.output, values)
    finally:
        logout(args, token)


def configure(args):
    token, _user = login(args)
    try:
        library_map = folders(args, token)
        anime_id = (library_map.get("Anime") or {}).get("ItemId", "")
        desired = {
            "f5a34f7b-2e8a-4e6a-a722-3a216a81b374": {
                "AllowExternalScriptUrls": False,
                "DisableScriptInjectionMiddleware": False,
                "CustomJavaScripts": [
                    {
                        "Name": "KefinTweaks-Config",
                        "Script": "window.KefinTweaksConfig = " + json.dumps({
                            "kefinTweaksRoot": "/web/KefinTweaks/",
                            "kefinTweaksRootResolved": "/web/KefinTweaks/",
                            "enabled": True,
                            "scripts": {
                                "watchlist": True, "homeScreen": True, "search": True,
                                "headerTabs": True, "customMenuLinks": True,
                                "breadcrumbs": True, "playlist": True,
                                "itemDetailsCollections": True, "flattenSingleSeasonShows": True,
                                "seriesInfo": True, "versionPreferences": True,
                                "collections": True, "backdropLeakFix": True,
                                "dashboardButtonFix": True, "infiniteScroll": True,
                                "removeContinue": True, "subtitleSearch": True,
                                "skinManager": True, "thumbnailScrubber": False,
                                "watchTogether": False, "userManager": False,
                            },
                            "search": {"enableJellyseerr": False},
                            "skins": [{
                                "name": "VeinFin Cinematic", "author": "VeinFin",
                                "url": [{"majorServerVersions": [11], "urls": ["/web/KefinTweaks/veinfin-cinematic.css"]}],
                                "colorSchemes": [], "enabled": True,
                            }],
                            "defaultSkin": "VeinFin Cinematic",
                            "themes": [], "customMenuLinks": [], "optionalIncludes": [],
                            "updateState": {"dismissed": True, "latestVersion": "0.5.3"},
                        }, separators=(",", ":")) + ";",
                        "Src": "", "Module": False, "Enabled": True,
                        "RequiresAuthentication": False,
                    },
                    {
                        "Name": "KefinTweaks-Injector",
                        "Script": "const s=document.createElement('script');s.src='/web/KefinTweaks/injector.js';s.async=true;document.head.appendChild(s);",
                        "Src": "", "Module": False, "Enabled": True,
                        "RequiresAuthentication": False,
                    },
                ],
            },
            "d7e11d57-819b-4bdd-a88d-53c5f5560225": {
                "IsEnabled": True, "EnableVideoBackdrop": True, "FullWidthVideo": True,
                "EnableMobileVideo": True, "ShowTrailerButton": True,
                "EnableClientSideSettings": True, "StartMuted": True,
                "DefaultTrailerVolume": 40, "TransitionEffect": "Fade",
                "SlideAnimationEnabled": True, "ShowProgressBar": True,
                "ShowPaginationDots": True, "UseSponsorBlock": True,
            },
            "b8298e01-2697-407a-b44d-aa8dc795e850": {
                "Enabled": True, "AllowUserOverride": True, "LazyLoadEnabled": True,
                "NumSectionsPerPage": 8, "DefaultTVShowsLibraryId": anime_id,
                "SectionSettings": [
                    {"SectionId": "MyMedia", "Enabled": True, "AllowUserOverride": True, "LowerLimit": 0, "UpperLimit": 12, "OrderIndex": 0, "ViewMode": "Portrait", "HideWatchedItems": False, "PluginConfigurations": []},
                    {"SectionId": "ContinueWatching", "Enabled": True, "AllowUserOverride": True, "LowerLimit": 0, "UpperLimit": 12, "OrderIndex": 1, "ViewMode": "Landscape", "HideWatchedItems": False, "PluginConfigurations": []},
                    {"SectionId": "NextUp", "Enabled": True, "AllowUserOverride": True, "LowerLimit": 0, "UpperLimit": 12, "OrderIndex": 2, "ViewMode": "Landscape", "HideWatchedItems": False, "PluginConfigurations": []},
                    {"SectionId": "RecentlyAddedShows", "Enabled": True, "AllowUserOverride": True, "LowerLimit": 0, "UpperLimit": 20, "OrderIndex": 3, "ViewMode": "Landscape", "HideWatchedItems": False, "PluginConfigurations": []},
                ],
            },
            "82c71cde-a52b-44f1-a18e-d93eb6a35ed0": {
                "EnableHoverPreview": True, "InjectClientScript": True,
                "EnableThemeVideoFallback": True, "EnableTrailerControls": True,
                "EnableTrailerLoop": True, "EnablePreviewAudio": False,
                "HoverDelayMs": 850, "PreviewBorderRadius": 12,
            },
            "73833d5f-0bcb-45dc-ab8b-7ce668f4345d": {
                "AutoClosePreview": True, "DisplayAdditionalVideoParts": True,
                "DisplayMissingEpisodes": False, "ShowWatchProgress": True,
                "ShowWatchedCount": True, "EpisodePageSize": 10,
            },
            "c83d86bb-a1e0-4c35-a113-e2101cf4ee6b": {
                "AutoDetectIntros": True, "UpdateMediaSegments": True,
                "UseFileTransformationPlugin": False,
                "EnableMainMenu": True,
            },
            "f69e946a-4b3c-4e9a-8f0a-8d7c1b2c4d9b": {
                "ShowWatchProgress": True, "ShowAudioLanguages": True,
                "PauseScreenEnabled": True, "ThemeSelectorEnabled": True,
                "PluginIconsEnabled": True, "ColoredRatingsEnabled": True,
                "AnalyticsEnabled": False, "JellyseerrEnabled": False,
                "DisableScriptInjectionMiddleware": False,
            },
        }
        for guid, changes in desired.items():
            path = f"/Plugins/{guid}/Configuration"
            current = request(args.base_url, "GET", path, token)
            missing = set(changes) - set(current)
            if missing:
                fail(f"candidate plugin schema changed for {guid}: {sorted(missing)}")
            current.update(changes)
            request(args.base_url, "POST", path, token, current)
            actual = request(args.base_url, "GET", path, token)
            if any(actual.get(key) != value for key, value in changes.items()):
                fail(f"candidate plugin configuration did not persist for {guid}")
        atomic_json(args.output, {guid: desired[guid] for guid in sorted(desired)})
    finally:
        logout(args, token)


def run_task(args):
    token, user = login(args)
    try:
        tasks = request(args.base_url, "GET", "/ScheduledTasks", token)
        matches = [task for task in tasks if task.get("Key") == args.task_key]
        if len(matches) != 1:
            fail("candidate scheduled task is missing or duplicated")
        task = matches[0]
        before = (task.get("LastExecutionResult") or {}).get("EndTimeUtc")
        request(args.base_url, "POST", f"/ScheduledTasks/Running/{task['Id']}", token)
        deadline = time.monotonic() + args.scan_timeout
        while time.monotonic() < deadline:
            tasks = request(args.base_url, "GET", "/ScheduledTasks", token)
            task = next(item for item in tasks if item.get("Key") == args.task_key)
            result = task.get("LastExecutionResult") or {}
            if task.get("State") == "Idle" and result.get("EndTimeUtc") != before:
                if result.get("Status") != "Completed":
                    fail("candidate scheduled task did not complete successfully")
                break
            time.sleep(5)
        else:
            fail("candidate scheduled task timed out")
        items = request(args.base_url, "GET", f"/Users/{user['Id']}/Items", token, query={
            "Recursive": "true", "IncludeItemTypes": "Episode", "Limit": 10000,
        }).get("Items", [])
        with_segments = 0
        segment_counts = {}
        first_item = None
        for item in items:
            value = request(args.base_url, "GET", f"/MediaSegments/{item['Id']}", token) or {}
            segments = value.get("Items", []) if isinstance(value, dict) else value
            if segments:
                with_segments += 1
                first_item = first_item or item["Id"]
                for segment in segments:
                    kind = str(segment.get("Type", "Unknown"))
                    segment_counts[kind] = segment_counts.get(kind, 0) + 1
        atomic_json(args.output, {
            "task_key": args.task_key, "status": "Completed", "episodes": len(items),
            "episodes_with_segments": with_segments, "segment_counts": segment_counts,
            "browser_test_item_id": first_item,
        })
    finally:
        logout(args, token)


def sync_user_state(args):
    production_args = argparse.Namespace(**vars(args))
    production_args.base_url = args.production_base_url
    production_token, production_user = login(production_args)
    candidate_token, candidate_user = login(args)
    try:
        query = {"Recursive": "true", "Fields": "Path", "Limit": 10000}
        production_items = request(
            production_args.base_url, "GET",
            f"/Users/{production_user['Id']}/Items", production_token, query=query,
        ).get("Items", [])
        candidate_items = request(
            args.base_url, "GET", f"/Users/{candidate_user['Id']}/Items",
            candidate_token, query=query,
        ).get("Items", [])
        candidate_by_path = {
            item.get("Path"): item for item in candidate_items if item.get("Path")
        }
        fields = (
            "PlaybackPositionTicks", "PlayCount", "IsFavorite", "Played",
            "LastPlayedDate", "Rating", "Likes",
        )
        expected = {}
        applied = 0
        for source in production_items:
            path = source.get("Path")
            target = candidate_by_path.get(path)
            if not target:
                continue
            source_data = source.get("UserData") or {}
            payload = {key: source_data.get(key) for key in fields if key in source_data}
            payload["ItemId"] = target["Id"]
            request(args.base_url, "POST", f"/UserItems/{target['Id']}/UserData", candidate_token, payload)
            expected[target["Id"]] = payload
            applied += 1
        production_configuration = production_user.get("Configuration")
        if isinstance(production_configuration, dict):
            request(args.base_url, "POST", "/Users/Configuration", candidate_token, production_configuration)
        for item_id, wanted in expected.items():
            actual = request(args.base_url, "GET", f"/UserItems/{item_id}/UserData", candidate_token)
            for key, value in wanted.items():
                if key == "ItemId":
                    continue
                if actual.get(key) != value:
                    fail(f"candidate user state field did not persist: {key}")
        atomic_json(args.output, {
            "production_items": len(production_items),
            "candidate_items": len(candidate_items),
            "matched_and_applied": applied,
            "unmatched_production_items": sum(
                1 for item in production_items
                if item.get("Path") and item.get("Path") not in candidate_by_path
            ),
            "configuration_preserved": isinstance(production_configuration, dict),
        })
    finally:
        logout(args, candidate_token)
        logout(production_args, production_token)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=("bootstrap", "libraries", "snapshot", "plugin-configs", "configure", "run-task", "sync-user-state"))
    parser.add_argument("--base-url", default="http://127.0.0.1:18096")
    parser.add_argument("--username", required=True)
    parser.add_argument("--password-file", required=True)
    parser.add_argument("--output")
    parser.add_argument("--scan", action="store_true")
    parser.add_argument("--scan-timeout", type=int, default=7200)
    parser.add_argument("--guid", action="append", default=[])
    parser.add_argument("--task-key")
    parser.add_argument("--production-base-url", default="http://127.0.0.1:8096")
    args = parser.parse_args()
    if args.command == "bootstrap":
        bootstrap(args)
    elif args.command == "libraries":
        if not args.output:
            fail("libraries requires --output")
        libraries(args)
    elif args.command == "snapshot":
        if not args.output:
            fail("snapshot requires --output")
        snapshot(args)
    elif args.command == "plugin-configs":
        if not args.output or not args.guid:
            fail("plugin-configs requires --output and --guid")
        plugin_configs(args)
    elif args.command == "configure":
        if not args.output:
            fail("configure requires --output")
        configure(args)
    elif args.command == "run-task":
        if not args.output or not args.task_key:
            fail("run-task requires --output and --task-key")
        run_task(args)
    else:
        if not args.output:
            fail("sync-user-state requires --output")
        sync_user_state(args)


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, OSError, urllib.error.URLError, ValueError) as error:
        print(f"ERROR: {error}", file=os.sys.stderr)
        raise SystemExit(1)

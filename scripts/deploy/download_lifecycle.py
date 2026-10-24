#!/usr/bin/env python3
"""Download lifecycle setup download-lifecycle configuration and isolated synthetic proof."""

import argparse
import hashlib
import http.cookiejar
import ipaddress
import json
import os
import pathlib
import secrets
import shutil
import sqlite3
import sys
import time
import urllib.error
import urllib.parse
import urllib.request


ALLOWED_STOPPED = {"stoppedUP", "pausedUP"}
ACTIVE_STATES = {"allocating", "checkingDL", "checkingUP", "downloading", "forcedDL", "forcedMetaDL",
                 "forcedUP", "metaDL", "moving", "queuedDL", "queuedUP", "stalledDL", "stalledUP", "uploading"}
PLANNED_PREFS = {"max_ratio": 1.0, "max_seeding_time": 1440, "share_limits_mode": "MatchAny", "max_ratio_act": 0}


def parse_ssh_connection(value):
    if not isinstance(value, str) or not value or any(ord(char) < 32 or ord(char) == 127 for char in value):
        fail("SSH connection context is absent or malformed")
    fields = value.split(" ")
    if len(fields) != 4 or any(not field for field in fields):
        fail("SSH connection context is malformed")
    client, client_port, server, server_port = fields
    try:
        client = ipaddress.ip_address(client)
        server = ipaddress.ip_address(server)
        client_port = int(client_port)
        server_port = int(server_port)
    except ValueError:
        fail("SSH connection context is malformed")
    if not (1 <= client_port <= 65535 and 1 <= server_port <= 65535):
        fail("SSH connection context is malformed")
    return client, client_port, server, server_port


def parse_socket_endpoint(value):
    if value.startswith("["):
        close = value.rfind("]:")
        if close < 0:
            fail("established SSH socket data is malformed")
        address, port = value[1:close], value[close + 2:]
    else:
        address, separator, port = value.rpartition(":")
        if not separator:
            fail("established SSH socket data is malformed")
    address = address.split("%", 1)[0]
    try:
        return ipaddress.ip_address(address), int(port)
    except ValueError:
        fail("established SSH socket data is malformed")


def ssh_session_matches(connection, socket_output):
    client, client_port, server, server_port = parse_ssh_connection(connection)
    matches = 0
    for line in socket_output.splitlines():
        fields = line.split()
        if len(fields) < 2:
            continue
        try:
            local, peer = parse_socket_endpoint(fields[-2]), parse_socket_endpoint(fields[-1])
        except RuntimeError:
            continue
        if local == (server, server_port) and peer == (client, client_port):
            matches += 1
    return matches == 1


def validate_ssh_mode():
    connection = os.environ.get("SSH_CONNECTION", "")
    if not ssh_session_matches(connection, sys.stdin.read()):
        fail("SSH connection context does not match the current established session")
    print("SSH_CONTEXT=VALID")


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


def atomic_bytes(path, data, uid=0, gid=0):
    path = pathlib.Path(path)
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(path.parent, 0o700)
    temporary = path.parent / f".{path.name}.{secrets.token_hex(8)}"
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(data); stream.flush(); os.fsync(stream.fileno())
        if os.geteuid() == 0:
            os.chown(temporary, uid, gid)
        os.replace(temporary, path)
    finally:
        if temporary.exists(): temporary.unlink()


def atomic_json(path, value, uid=0, gid=0):
    atomic_bytes(path, (json.dumps(value, indent=2, sort_keys=True) + "\n").encode(), uid, gid)


def protected_json(path):
    path = pathlib.Path(path)
    if not path.is_file() or path.is_symlink() or file_mode(path) != 0o600:
        fail(f"protected state is missing or unsafe: {path.name}")
    return json.loads(path.read_text(encoding="utf-8"))


def policy(path):
    value = json.loads(pathlib.Path(path).read_text(encoding="utf-8"))
    if value.get("schema") != 1 or value.get("qbittorrent_version") != "5.3.0": fail("policy version drift")
    if (value.get("ratio_limit"), value.get("seeding_time_minutes"), value.get("share_limits_mode"),
            value.get("share_limit_action"), value.get("share_limit_action_api_value")) != (1.0, 1440, "MatchAny", "Stop", 0):
        fail("share-limit policy drift")
    if value.get("categories") != {"movies": "/data/torrents/movies", "tv": "/data/torrents/tv", "anime": "/data/torrents/anime"}:
        fail("category policy drift")
    return value


def request(method, url, body=None, headers=None, opener=None, form=False, allowed=(200, 201, 202, 204)):
    headers = dict(headers or {})
    if body is None: data = None
    elif form:
        data = urllib.parse.urlencode(body).encode(); headers["Content-Type"] = "application/x-www-form-urlencoded"
    else:
        data = json.dumps(body, separators=(",", ":")).encode(); headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, method=method, headers=headers)
    try:
        call = opener.open if opener else urllib.request.urlopen
        with call(req, timeout=30) as response:
            raw = response.read()
            if response.status not in allowed: fail(f"HTTP {response.status}")
            if not raw:
                return None
            try:
                return json.loads(raw)
            except json.JSONDecodeError:
                return raw.decode("utf-8")
    except urllib.error.HTTPError as error:
        fail(f"request failed for {urllib.parse.urlsplit(url).path} (HTTP {error.code})")


class Qbit:
    def __init__(self, username, password):
        jar = http.cookiejar.CookieJar()
        self.opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))
        result = request("POST", "http://127.0.0.1:8080/api/v2/auth/login",
                         {"username": username, "password": password}, opener=self.opener, form=True)
        if not list(jar): fail("qBittorrent authentication failed")

    def get(self, path): return request("GET", "http://127.0.0.1:8080/api/v2/" + path, opener=self.opener)
    def get_raw(self, path):
        with self.opener.open("http://127.0.0.1:8080/api/v2/" + path, timeout=30) as response: return response.read()
    def post(self, path, body): return request("POST", "http://127.0.0.1:8080/api/v2/" + path, body, opener=self.opener, form=True)
    def set_preferences(self, values): self.post("app/setPreferences", {"json": json.dumps(values, separators=(",", ":"))})

    def multipart(self, path, fields, filename, content):
        boundary = "VeinFin" + secrets.token_hex(16)
        parts = []
        for name, value in fields.items():
            parts += [f"--{boundary}\r\nContent-Disposition: form-data; name=\"{name}\"\r\n\r\n{value}\r\n".encode()]
        parts += [f"--{boundary}\r\nContent-Disposition: form-data; name=\"torrents\"; filename=\"{filename}\"\r\nContent-Type: application/x-bittorrent\r\n\r\n".encode(), content, f"\r\n--{boundary}--\r\n".encode()]
        req = urllib.request.Request("http://127.0.0.1:8080/api/v2/" + path, data=b"".join(parts), method="POST",
                                     headers={"Content-Type": f"multipart/form-data; boundary={boundary}"})
        with self.opener.open(req, timeout=30) as response:
            # The response body is version-dependent and is never admission proof.
            # HTTP success is only transport acknowledgement; callers must prove the
            # exact locally computed info hash through torrents/info.
            return response.read()


class Arr:
    def __init__(self, name, key):
        self.name = name; port = {"sonarr": 8989, "radarr": 7878, "prowlarr": 9696}[name]
        self.base = f"http://127.0.0.1:{port}/api/{'v1' if name == 'prowlarr' else 'v3'}/"
        self.headers = {"X-Api-Key": key}
    def get(self, path): return request("GET", self.base + path, headers=self.headers)
    def put(self, path, body): return request("PUT", self.base + path, body, self.headers)


class Bazarr:
    def __init__(self, key): self.headers = {"X-API-KEY": key}
    def get(self, path): return request("GET", "http://127.0.0.1:6767/api/" + path, headers=self.headers)


def seerr_snapshot(username, password):
    jar = http.cookiejar.CookieJar(); opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))
    request("POST", "http://127.0.0.1:5055/api/v1/auth/jellyfin",
            {"username": username, "password": password}, opener=opener)
    if not list(jar): fail("Seerr authentication failed")
    get = lambda path: request("GET", "http://127.0.0.1:5055/api/v1/" + path, opener=opener)
    return {"sonarr": get("settings/sonarr"), "radarr": get("settings/radarr"),
            "requests": get("request?take=1&skip=0")}


def clients(args):
    return {name: Arr(name, read_secret(getattr(args, f"{name}_key_file"))) for name in ("sonarr", "radarr", "prowlarr")}


def qbit(args): return Qbit(args.username, read_secret(args.password_file))


def snapshot(args):
    q = qbit(args); apps = clients(args); password = read_secret(args.password_file)
    result = {"qbit": {"version": q.get_raw("app/version").decode(), "preferences": q.get("app/preferences"),
                       "categories": q.get("torrents/categories"), "torrents": q.get("torrents/info"), "tags": q.get_raw("torrents/tags").decode()}, "arr": {}}
    for name in ("sonarr", "radarr"):
        app = apps[name]
        result["arr"][name] = {"download_config": app.get("config/downloadclient"), "download_clients": app.get("downloadclient"),
                               "media_management": app.get("config/mediamanagement"), "remote_paths": app.get("remotepathmapping"),
                               "queue": app.get("queue?page=1&pageSize=100"), "history": app.get("history?page=1&pageSize=100"),
                               "commands": app.get("command"),
                               "quality_profiles": app.get("qualityprofile"), "root_folders": app.get("rootfolder")}
    result["arr"]["sonarr"]["series"] = apps["sonarr"].get("series")
    result["arr"]["radarr"]["movies"] = apps["radarr"].get("movie")
    result["arr"]["prowlarr"] = {"indexers": apps["prowlarr"].get("indexer"), "applications": apps["prowlarr"].get("applications"),
                                      "history": apps["prowlarr"].get("history?page=1&pageSize=100"), "commands": apps["prowlarr"].get("command")}
    bazarr = Bazarr(read_secret(args.bazarr_key_file))
    result["bazarr"] = {key: bazarr.get(endpoint) for key, endpoint in {
        "settings": "system/settings", "profiles": "system/languages/profiles",
        "episodes_wanted": "episodes/wanted?start=0&length=1", "movies_wanted": "movies/wanted?start=0&length=1",
        "episodes_history": "episodes/history?start=0&length=1", "movies_history": "movies/history?start=0&length=1"}.items()}
    result["seerr"] = seerr_snapshot(args.username, password)
    return result


def assert_empty_activity(state):
    if state["qbit"]["torrents"]: fail("qBittorrent contains torrents")
    prefs = state["qbit"]["preferences"]
    if prefs.get("save_path") != "/data/torrents" or not prefs.get("temp_path_enabled") or prefs.get("temp_path") != "/data/torrents/incomplete":
        fail("qBittorrent torrent paths changed")
    expected_categories = {"movies": "/data/torrents/movies", "tv": "/data/torrents/tv", "anime": "/data/torrents/anime"}
    actual_categories = {name: value.get("savePath") for name, value in state["qbit"]["categories"].items()}
    if actual_categories != expected_categories: fail("qBittorrent category routing changed")
    if prefs.get("upnp") or prefs.get("web_ui_upnp") or prefs.get("scan_dirs") or prefs.get("auto_delete_mode") != 0:
        fail("qBittorrent ingress or deletion safety changed")
    for name in ("sonarr", "radarr"):
        queue = state["arr"][name]["queue"]
        if int(queue.get("totalRecords", -1)) != 0: fail(f"{name} queue is not empty")
        if any(str(x.get("status", "")).lower() in {"queued", "started"} for x in state["arr"][name]["commands"]):
            fail(f"{name} has an active command")
    if state["arr"]["radarr"]["movies"]: fail("Radarr contains movies")
    series = state["arr"]["sonarr"]["series"]
    if len(series) != 1 or series[0].get("monitored"): fail("existing Sonarr series changed")
    if any(str(x.get("status", "")).lower() in {"queued", "started"} for x in state["arr"]["prowlarr"]["commands"]):
        fail("Prowlarr has an active command")
    if int(state["seerr"]["requests"].get("pageInfo", {}).get("results", -1)) != 0: fail("Seerr contains requests")


def snapshot_mode(args):
    value = snapshot(args); assert_empty_activity(value); atomic_json(args.output, value); print("SNAPSHOT=RECORDED TORRENTS=0 QUEUES=0")


def sqlite_backup(source, destination):
    source_db = sqlite3.connect(f"file:{source}?mode=ro", uri=True); target_db = sqlite3.connect(destination)
    try:
        source_db.backup(target_db)
        if target_db.execute("PRAGMA integrity_check").fetchone()[0] != "ok": fail("database backup integrity failure")
    finally: target_db.close(); source_db.close()
    os.chmod(destination, 0o600)
    if os.geteuid() == 0: os.chown(destination, 0, 0)


def backup_mode(args):
    destination = pathlib.Path(args.backup_dir)
    required = ("api-state.json", "sonarr.db", "radarr.db", "prowlarr.db", "qBittorrent.conf", "categories.json", "watched_folders.json", "manifest.json")
    if destination.exists():
        if (destination.is_symlink() or file_mode(destination) != 0o700
                or any(not (destination/x).is_file() or (destination/x).is_symlink() or file_mode(destination/x) != 0o600 for x in required)):
            fail("existing Download lifecycle setup backup is unsafe or incomplete")
        print("BACKUP=PRESERVED"); return
    temporary = destination.parent / f".{destination.name}.{secrets.token_hex(8)}"; temporary.mkdir(mode=0o700)
    root = pathlib.Path(args.config_root)
    try:
        sqlite_backup(root/"sonarr/sonarr.db", temporary/"sonarr.db"); sqlite_backup(root/"radarr/radarr.db", temporary/"radarr.db"); sqlite_backup(root/"prowlarr/prowlarr.db", temporary/"prowlarr.db")
        for source, name in ((pathlib.Path(args.before), "api-state.json"), (root/"qbittorrent/qBittorrent/qBittorrent.conf", "qBittorrent.conf"),
                             (root/"qbittorrent/qBittorrent/categories.json", "categories.json"), (root/"qbittorrent/qBittorrent/watched_folders.json", "watched_folders.json")):
            atomic_bytes(temporary/name, source.read_bytes())
        atomic_json(temporary/"manifest.json", {"schema": 1, "integrity": "ok", "media_included": False, "database_restore_requires_container_stop": True})
        os.replace(temporary, destination)
    finally:
        if temporary.exists(): shutil.rmtree(temporary)
    print("BACKUP=CREATED INTEGRITY=PASS")


def field(resource, name):
    matches = [x for x in resource.get("fields", []) if x.get("name") == name]
    if len(matches) != 1: fail(f"API schema field unavailable: {name}")
    return matches[0]


def planned_summary(args):
    current = snapshot(args); assert_empty_activity(current); pol = policy(args.policy)
    changes = []
    prefs = current["qbit"]["preferences"]
    for key, value in PLANNED_PREFS.items():
        if prefs.get(key) != value: changes.append({"component": "qbittorrent", "setting": key, "from": prefs.get(key), "to": value})
    for app in ("sonarr", "radarr"):
        for client in current["arr"][app]["download_clients"]:
            if client.get("removeFailedDownloads") is not False: changes.append({"component": app, "setting": "removeFailedDownloads", "from": bool(client.get("removeFailedDownloads")), "to": False})
    for indexer in current["arr"]["prowlarr"]["indexers"]:
        for name, value in (("torrentBaseSettings.seedRatio", 1.0), ("torrentBaseSettings.seedTime", 1440), ("torrentBaseSettings.packSeedTime", 1440)):
            if field(indexer, name).get("value") != value: changes.append({"component": "prowlarr", "setting": name, "from": field(indexer, name).get("value"), "to": value})
    result = {"schema": 1, "policy": {k: pol[k] for k in ("qbittorrent_version","ratio_limit","seeding_time_minutes","share_limits_mode","share_limit_action")},
              "changes": changes, "cleanup_candidates": 0, "deletions": 0, "media_actions": 0}
    atomic_json(args.output, result); print(f"PREVIEW=PASS CHANGES={len(changes)} CLEANUP_CANDIDATES=0 DELETIONS=0")


def apply_config(args):
    pol = policy(args.policy); q = qbit(args); apps = clients(args)
    q.set_preferences(PLANNED_PREFS)
    for app_name in ("sonarr", "radarr"):
        app = apps[app_name]
        config = app.get("config/downloadclient")
        if not config.get("enableCompletedDownloadHandling"):
            config["enableCompletedDownloadHandling"] = True; app.put(f"config/downloadclient/{config['id']}", config)
        for client in app.get("downloadclient"):
            client["removeCompletedDownloads"] = True; client["removeFailedDownloads"] = False
            app.put(f"downloadclient/{client['id']}", client)
    for indexer in apps["prowlarr"].get("indexer"):
        if not indexer.get("enable"): continue
        field(indexer, "torrentBaseSettings.seedRatio")["value"] = pol["ratio_limit"]
        field(indexer, "torrentBaseSettings.seedTime")["value"] = pol["seeding_time_minutes"]
        field(indexer, "torrentBaseSettings.packSeedTime")["value"] = pol["seeding_time_minutes"]
        apps["prowlarr"].put(f"indexer/{indexer['id']}", indexer)
    print("CONFIGURED=1 QBIT_MODE=MatchAny QBIT_ACTION=Stop FAILED_REMOVAL=DISABLED")


def bencode(value):
    if isinstance(value, int): return b"i"+str(value).encode()+b"e"
    if isinstance(value, bytes): return str(len(value)).encode()+b":"+value
    if isinstance(value, str): return bencode(value.encode())
    if isinstance(value, list): return b"l"+b"".join(bencode(x) for x in value)+b"e"
    if isinstance(value, dict): return b"d"+b"".join(bencode(k)+bencode(value[k]) for k in sorted(value, key=lambda x: x.encode() if isinstance(x,str) else x))+b"e"
    fail("unsupported bencode value")


def torrent_bytes(name, payload):
    piece = 16384; pieces = b"".join(hashlib.sha1(payload[i:i+piece]).digest() for i in range(0,len(payload),piece))
    info = {"length": len(payload), "name": name, "piece length": piece, "pieces": pieces, "private": 1}
    info_bytes = bencode(info)
    metadata = b"d10:created by28:VeinFin synthetic validation13:creation datei0e4:info" + info_bytes + b"e"
    return metadata, hashlib.sha1(info_bytes).hexdigest(), info_bytes


def _torrent_matches(torrent, expected):
    tags = {item.strip() for item in str(torrent.get("tags", "")).split(",") if item.strip()}
    return (str(torrent.get("hash", "")).lower() == expected["hash"]
            and torrent.get("name") == expected["name"]
            and torrent.get("category") == expected["category"]
            and tags == {expected["tag"]}
            and int(torrent.get("size", -1)) == expected["size"])


def admit_torrent(q, metadata, torrent_hash, name, size, fields, attempts=90, sleep_fn=time.sleep):
    expected = {"hash": torrent_hash.lower(), "name": name, "size": size,
                "category": fields["category"], "tag": fields["tags"]}
    existing = q.get("torrents/info")
    if any(str(item.get("hash", "")).lower() == expected["hash"] or item.get("name") == name for item in existing):
        fail("synthetic torrent hash or name already exists")
    q.multipart("torrents/add", fields, name + ".torrent", metadata)
    for _ in range(attempts):
        inventory = q.get("torrents/info")
        by_hash = [item for item in inventory if str(item.get("hash", "")).lower() == expected["hash"]]
        by_name = [item for item in inventory if item.get("name") == name]
        if len(by_hash) > 1 or len(by_name) > 1:
            fail("duplicate synthetic torrent identity detected")
        if len(by_hash) == 1:
            if len(by_name) != 1 or not _torrent_matches(by_hash[0], expected):
                fail("admitted synthetic torrent conflicts with expected identity")
            return by_hash[0]
        if by_name:
            fail("synthetic torrent name appeared with an unexpected hash")
        sleep_fn(1)
    fail("transport succeeded but exact synthetic info hash was not admitted")


def _pure_container_path(value):
    if not isinstance(value, str) or not value.startswith("/") or ".." in pathlib.PurePosixPath(value).parts:
        fail("unsafe container path")
    normalized = pathlib.PurePosixPath(os.path.normpath(value))
    if not normalized.is_absolute(): fail("container path is not absolute")
    return normalized


def _reject_symlink_chain(path, stop):
    current = path
    while True:
        if current.exists() and current.is_symlink(): fail("validation path contains a symbolic link")
        if current == stop: return
        if stop not in current.parents: fail("validation path escaped its host root")
        current = current.parent


def container_to_host(container_path, media_root):
    container = _pure_container_path(container_path)
    container_root = pathlib.PurePosixPath("/data/torrents")
    try: relative = container.relative_to(container_root)
    except ValueError: fail("container path is outside the qBittorrent bind mount")
    allowed_container = (container_root / ".veinfin-download_lifecycle-validation",
                         container_root / "incomplete/.veinfin-download_lifecycle-validation")
    if not any(root == container or root in container.parents for root in allowed_container):
        fail("container path is outside the Download lifecycle setup validation namespace")
    if relative.parts and relative.parts[0] in {"movies", "tv", "anime"}:
        fail("validation path overlaps a production category")
    media = pathlib.Path(media_root).resolve()
    torrent_root = (media / "torrents").resolve()
    _reject_symlink_chain(torrent_root, media)
    host = torrent_root.joinpath(*relative.parts)
    _reject_symlink_chain(host, torrent_root)
    resolved = host.resolve(strict=False)
    try: resolved.relative_to(torrent_root)
    except ValueError: fail("translated host path escaped the torrent bind mount")
    return resolved


def validate_single_file(q, torrent_hash, expected_name, expected_size, require_complete=False):
    files = q.get("torrents/files?hash=" + torrent_hash)
    if not isinstance(files, list) or len(files) != 1: fail("synthetic torrent does not contain exactly one file")
    item = files[0]
    if item.get("name") != expected_name or int(item.get("size", -1)) != expected_size:
        fail("synthetic torrent file identity changed")
    if require_complete and float(item.get("progress", -1)) != 1.0:
        fail("synthetic torrent file is not complete")
    return item


def validate_network_isolation(q, torrent_hash, torrent):
    properties = q.get("torrents/properties?hash=" + torrent_hash)
    trackers = q.get("torrents/trackers?hash=" + torrent_hash)
    webseeds = q.get("torrents/webseeds?hash=" + torrent_hash)
    peers = q.get("sync/torrentPeers?hash=" + torrent_hash + "&rid=0")
    external_trackers = [item for item in trackers if str(item.get("url", "")).lower().startswith(("http://", "https://", "udp://", "ws://", "wss://"))]
    if not properties.get("isPrivate") or external_trackers or webseeds or (peers.get("peers") or {}):
        fail("synthetic torrent network isolation failed")
    if int(torrent.get("downloaded", 0)) != 0 or int(torrent.get("downloaded_session", 0)) != 0:
        fail("synthetic torrent received external bytes")
    return {"private": True, "trackers": 0, "webseeds": 0, "peers": 0,
            "dht": False, "pex": False, "lsd": False, "external_downloaded_bytes": 0}


def wait_torrent(q, torrent_hash, states=None, absent=False, timeout=90):
    deadline = time.monotonic()+timeout
    while time.monotonic()<deadline:
        values=q.get("torrents/info?hashes="+torrent_hash)
        if absent and not values: return None
        if values and (states is None or values[0].get("state") in states): return values[0]
        time.sleep(1)
    fail("synthetic torrent state timed out")


def wait_complete(q, torrent_hash, expected_name, expected_size, media_root, attempts=180, sleep_fn=time.sleep):
    observations=[]
    for _ in range(attempts):
        values=q.get("torrents/info?hashes="+torrent_hash)
        if len(values) != 1: fail("exact synthetic torrent disappeared or duplicated")
        torrent=values[0]
        observations.append({"state":torrent.get("state"),"progress":torrent.get("progress"),
                             "amount_left":torrent.get("amount_left"),"content_path":torrent.get("content_path")})
        if (torrent.get("state") in ALLOWED_STOPPED and float(torrent.get("progress",-1)) == 1.0
                and int(torrent.get("amount_left",-1)) == 0):
            validate_single_file(q,torrent_hash,expected_name,expected_size,require_complete=True)
            host=container_to_host(torrent["content_path"],media_root)
            return torrent,host,observations
        sleep_fn(1)
    fail("synthetic torrent did not reach a stopped completed state")


def cleanup_decision(torrent, evidence, ratio_limit=1.0, seeding_minutes=1440, validation_root=None):
    if not isinstance(torrent, dict) or not isinstance(evidence, dict): return False, "malformed-input"
    required = ("state","progress","ratio","seeding_time","category","save_path","content_path")
    if any(k not in torrent for k in required): return False, "malformed-torrent"
    if evidence.get("status") != "successful" or not evidence.get("files"): return False, "import-evidence-missing"
    if evidence.get("partial") or evidence.get("failed"): return False, "import-not-complete"
    if len(evidence["files"]) != int(evidence.get("expected_files", -1)): return False, "partial-import"
    if torrent["state"] in ACTIVE_STATES or torrent["state"] not in ALLOWED_STOPPED: return False, "torrent-not-stopped-complete"
    try:
        progress=float(torrent["progress"]); ratio=float(torrent["ratio"]); seeded=int(torrent["seeding_time"])
    except (TypeError, ValueError):
        return False, "malformed-torrent"
    if progress != 1.0: return False, "torrent-incomplete"
    if not (ratio >= ratio_limit or seeded >= seeding_minutes*60): return False, "share-limit-not-reached"
    if torrent.get("category") not in {"movies","tv","anime","download_lifecycle-validation"}: return False, "unknown-category"
    if validation_root:
        if str(validation_root).startswith("/data/"):
            root=pathlib.PurePosixPath(os.path.normpath(validation_root))
            save=pathlib.PurePosixPath(os.path.normpath(torrent["save_path"]))
            content=pathlib.PurePosixPath(os.path.normpath(torrent["content_path"]))
        else:
            root=pathlib.Path(validation_root).resolve(); save=pathlib.Path(torrent["save_path"]).resolve(); content=pathlib.Path(torrent["content_path"]).resolve()
        try: save.relative_to(root); content.relative_to(root)
        except ValueError: return False, "path-outside-validation-root"
    for item in evidence["files"]:
        if not all(item.get(k) for k in ("source_exists","import_exists","same_device","same_inode","same_bytes")): return False, "hardlink-proof-failed"
        if int(item.get("link_count",0)) < 2: return False, "hardlink-proof-failed"
    return True, "eligible"


def fixture(q, media_root, label, uid, gid):
    name=f"{label}.bin"; payload=(f"VeinFin Download lifecycle setup synthetic fixture {label}\n".encode()*1024)
    metadata,torrent_hash,info_bytes=torrent_bytes(name,payload)
    fields={"savepath":f"/data/torrents/.veinfin-download_lifecycle-validation/{label}/source",
            "downloadPath":f"/data/torrents/incomplete/.veinfin-download_lifecycle-validation/{label}",
            "useDownloadPath":"true","category":"download_lifecycle-validation","tags":"download_lifecycle-validation",
            "stopped":"true","autoTMM":"false"}
    admitted=admit_torrent(q,metadata,torrent_hash,name,len(payload),fields)
    validate_single_file(q,torrent_hash,name,len(payload))
    initial_host=container_to_host(admitted["content_path"],media_root)
    initial_host.parent.mkdir(mode=0o700,parents=True,exist_ok=True)
    for path in (initial_host.parent,): os.chown(path,uid,gid); os.chmod(path,0o700)
    if initial_host.exists() and (initial_host.is_symlink() or not initial_host.is_file()): fail("unexpected validation payload path")
    atomic_bytes(initial_host,payload,uid,gid)
    network=validate_network_isolation(q,torrent_hash,admitted)
    q.post("torrents/recheck",{"hashes":torrent_hash})
    torrent,final_host,observations=wait_complete(q,torrent_hash,name,len(payload),media_root)
    if not final_host.is_file() or final_host.is_symlink() or hashlib.sha256(final_host.read_bytes()).hexdigest()!=hashlib.sha256(payload).hexdigest():
        fail("completed synthetic payload bytes are unavailable")
    network=validate_network_isolation(q,torrent_hash,torrent)
    import_dir=pathlib.Path(media_root).resolve()/"torrents/.veinfin-download_lifecycle-validation"/label/"library-import"
    import_dir.mkdir(mode=0o700,parents=True,exist_ok=True); os.chown(import_dir,uid,gid); os.chmod(import_dir,0o700)
    return {"hash":torrent_hash,"torrent":torrent,"source":final_host,"imported":import_dir/name,
            "digest":hashlib.sha256(payload).hexdigest(),"metadata_sha256":hashlib.sha256(metadata).hexdigest(),
            "info_sha1":hashlib.sha1(info_bytes).hexdigest(),"initial_content_path":admitted["content_path"],
            "final_content_path":torrent["content_path"],"observations":observations,"network":network}


def remove_known(q, torrent_hash, delete_files=True):
    if q.get("torrents/info?hashes="+torrent_hash): q.post("torrents/delete",{"hashes":torrent_hash,"deleteFiles":"true" if delete_files else "false"}); wait_torrent(q,torrent_hash,absent=True)


def _remove_tree_exact(path, expected):
    path=pathlib.Path(path); expected=pathlib.Path(expected)
    if path != expected or path.is_symlink(): fail("refusing cleanup outside an exact validation root")
    if path.exists(): shutil.rmtree(path)


def teardown_validation(q, hashes, media_root):
    for torrent_hash in sorted(set(hashes)):
        values=q.get("torrents/info?hashes="+torrent_hash)
        if values:
            if len(values)!=1 or str(values[0].get("hash","")).lower()!=torrent_hash.lower() or values[0].get("name") not in {"successful.bin","unimported.bin"}:
                fail("refusing teardown of an unrecognized torrent")
            container_to_host(values[0].get("save_path",""),media_root)
            if values[0].get("content_path"): container_to_host(values[0]["content_path"],media_root)
            remove_known(q,torrent_hash,True)
    try: q.post("torrents/deleteTags",{"tags":"download_lifecycle-validation"})
    except Exception: pass
    try: q.post("torrents/removeCategories",{"categories":"download_lifecycle-validation"})
    except Exception: pass
    media=pathlib.Path(media_root).resolve()
    _remove_tree_exact(media/"torrents/.veinfin-download_lifecycle-validation",media/"torrents/.veinfin-download_lifecycle-validation")
    _remove_tree_exact(media/"torrents/incomplete/.veinfin-download_lifecycle-validation",media/"torrents/incomplete/.veinfin-download_lifecycle-validation")


def synthetic_mode(args):
    q=qbit(args); media=pathlib.Path(args.media_root).resolve(); root=pathlib.Path(args.validation_root).resolve()
    expected=media/"torrents/.veinfin-download_lifecycle-validation"; incomplete=media/"torrents/incomplete/.veinfin-download_lifecycle-validation"
    if root!=expected or root.exists() or incomplete.exists(): fail("validation roots are unsafe or already exist")
    known=[]; report={"schema":1,"network":{}}
    try:
        q.post("torrents/createCategory",{"category":"download_lifecycle-validation","savePath":"/data/torrents/.veinfin-download_lifecycle-validation"}); q.post("torrents/createTags",{"tags":"download_lifecycle-validation"})
        good_meta=torrent_bytes("successful.bin",(f"VeinFin Download lifecycle setup synthetic fixture successful\n".encode()*1024)); known.append(good_meta[1])
        good=fixture(q,media,"successful",args.uid,args.gid); torrent,source,imported,digest=good["torrent"],good["source"],good["imported"],good["digest"]
        os.link(source,imported); first=imported.read_bytes()[:1]
        changed=bytes([first[0]^0xff])
        with imported.open("r+b") as stream: stream.seek(0); stream.write(changed); stream.flush(); os.fsync(stream.fileno())
        if source.read_bytes()[:1]!=changed: fail("hardlink mutation was not visible through both paths")
        with imported.open("r+b") as stream: stream.seek(0); stream.write(first); stream.flush(); os.fsync(stream.fileno())
        a,b=source.stat(),imported.stat(); evidence={"status":"successful","expected_files":1,"partial":False,"failed":False,"files":[{"source_exists":source.exists(),"import_exists":imported.exists(),"same_device":a.st_dev==b.st_dev,"same_inode":a.st_ino==b.st_ino,"same_bytes":hashlib.sha256(source.read_bytes()).hexdigest()==digest==hashlib.sha256(imported.read_bytes()).hexdigest(),"link_count":a.st_nlink}]}
        if not all(evidence["files"][0].values()): fail("synthetic hardlink evidence is incomplete")
        physical=a.st_blocks*512; report["hardlink"]={"same_device":True,"same_inode":True,"link_count":a.st_nlink,"source_allocated_bytes":physical,"import_path_allocated_bytes":b.st_blocks*512,"unique_inode_count":1,"unique_allocated_bytes":physical,"bytes_identical":True,"mutation_visible":True}
        report["successful_import"]={"status":"successful","expected_files":1,"files":evidence["files"],"validation_cleanup_authorized":True,"production_threshold_elapsed":False}
        report["network"]=good["network"]; report["admission"]={k:good[k] for k in ("info_sha1","metadata_sha256","initial_content_path","final_content_path")}
        remove_known(q,good["hash"],True)
        if source.exists() or not imported.is_file() or hashlib.sha256(imported.read_bytes()).hexdigest()!=digest: fail("library hardlink did not survive source cleanup")
        imported.unlink(); known.remove(good["hash"]); report["successful_cleanup"]={"source_removed":True,"import_survived":True,"import_removed_after_proof":True,"authorization":"validation-only-after-hardlink-proof"}
        bad_meta=torrent_bytes("unimported.bin",(f"VeinFin Download lifecycle setup synthetic fixture unimported\n".encode()*1024)); known.append(bad_meta[1])
        bad=fixture(q,media,"unimported",args.uid,args.gid)
        eligible,reason=cleanup_decision(bad["torrent"],{},validation_root="/data/torrents/.veinfin-download_lifecycle-validation")
        if eligible or reason!="import-evidence-missing" or not bad["source"].exists() or bad["imported"].exists(): fail("unimported cleanup did not fail closed")
        report["unimported_refusal"]={"eligible":False,"reason":reason,"source_retained_before_manual_cleanup":True}
        remove_known(q,bad["hash"],True); known.remove(bad["hash"])
    finally:
        teardown_validation(q,known,media)
    if (q.get("torrents/info") or root.exists() or incomplete.exists()
            or "download_lifecycle-validation" in q.get("torrents/categories") or "download_lifecycle-validation" in q.get_raw("torrents/tags").decode().split(",")):
        fail("synthetic validation artifacts remain")
    report["final"]={"torrents":0,"files":0,"category":False,"tag":False}; atomic_json(args.output,report)
    print("SYNTHETIC=PASS HARDLINK=PASS CLEANUP=PASS UNIMPORTED_REFUSAL=PASS ARTIFACTS=0")


def cleanup_aborted_mode(args):
    """Remove only exact, positively identified Download lifecycle setup validation artifacts."""
    q=qbit(args); api_root=pathlib.PurePosixPath("/data/torrents/.veinfin-download_lifecycle-validation")
    candidates=[]
    for torrent in q.get("torrents/info"):
        save_raw=torrent.get("save_path", ""); content_raw=torrent.get("content_path", "")
        try:
            save=pathlib.PurePosixPath(os.path.normpath(save_raw)); save.relative_to(api_root)
            if content_raw:
                content=pathlib.PurePosixPath(os.path.normpath(content_raw))
                if content != pathlib.PurePosixPath("/data/torrents/incomplete") / torrent.get("name", ""):
                    content.relative_to(api_root)
        except (ValueError, TypeError):
            fail("torrent path is not an exact validation path; refusing recovery cleanup "
                 f"(save_under_root={str(save_raw).startswith(str(api_root) + '/')}, "
                 f"content_under_root={str(content_raw).startswith(str(api_root) + '/')})")
        if torrent.get("name") not in {"successful.bin", "unimported.bin"} or not torrent.get("hash"):
            fail("torrent identity is not an exact Download lifecycle setup validation fixture "
                 f"(recognized_name={torrent.get('name') in {'successful.bin','unimported.bin'}}, hash_present={bool(torrent.get('hash'))})")
        candidates.append(torrent["hash"])
    for torrent_hash in candidates: remove_known(q,torrent_hash,True)
    try: q.post("torrents/deleteTags",{"tags":"download_lifecycle-validation"})
    except Exception: pass
    try: q.post("torrents/removeCategories",{"categories":"download_lifecycle-validation"})
    except Exception: pass
    root=pathlib.Path(args.validation_root).resolve(); media=pathlib.Path(args.media_root).resolve()
    if root != media/"torrents/.veinfin-download_lifecycle-validation":
        fail("recovery validation root is unsafe")
    teardown_validation(q,[],media)
    if q.get("torrents/info") or root.exists(): fail("validation recovery cleanup is incomplete")
    print(f"RECOVERY_CLEANUP=PASS IDENTIFIED_TORRENTS={len(candidates)} ARTIFACTS=0")


def normalized_client(value):
    copy=json.loads(json.dumps(value)); copy["removeFailedDownloads"]=False; copy["removeCompletedDownloads"]=True; return copy


def normalized_download_config(value):
    copy=json.loads(json.dumps(value)); copy["enableCompletedDownloadHandling"]=True; return copy


def normalized_indexer(value):
    copy=json.loads(json.dumps(value))
    if copy.get("enable"):
        for name, wanted in (("torrentBaseSettings.seedRatio",1.0),("torrentBaseSettings.seedTime",1440),("torrentBaseSettings.packSeedTime",1440)):
            field(copy,name)["value"]=wanted
    return copy


def verify_mode(args):
    before=protected_json(args.before); now=snapshot(args); assert_empty_activity(now); pol=policy(args.policy)
    prefs=now["qbit"]["preferences"]
    if now["qbit"]["version"]!="v"+pol["qbittorrent_version"] or any(prefs.get(k)!=v for k,v in PLANNED_PREFS.items()): fail("qBittorrent lifecycle policy is incorrect")
    if prefs.get("upnp") or prefs.get("web_ui_upnp") or prefs.get("scan_dirs") or prefs.get("auto_delete_mode")!=0: fail("qBittorrent network/watch/delete safety changed")
    if now["qbit"]["categories"]!=before["qbit"]["categories"] or "download_lifecycle-validation" in now["qbit"]["tags"].split(","): fail("qBittorrent category or tag set changed")
    for app in ("sonarr","radarr"):
        old,new=before["arr"][app],now["arr"][app]
        for key in ("media_management","remote_paths","quality_profiles","root_folders","series" if app=="sonarr" else "movies"):
            if new[key]!=old[key]: fail(f"{app} protected state changed: {key}")
        if not new["download_config"].get("enableCompletedDownloadHandling") or not new["download_config"].get("autoRedownloadFailed"): fail(f"{app} download handling is disabled")
        if not new["media_management"].get("copyUsingHardlinks"): fail(f"{app} hardlink imports are disabled")
        if normalized_download_config(new["download_config"])!=normalized_download_config(old["download_config"]): fail(f"{app} download handling drifted")
        if [normalized_client(x) for x in new["download_clients"]]!=[normalized_client(x) for x in old["download_clients"]]: fail(f"{app} download-client state drifted")
        if any(not x.get("removeCompletedDownloads") or x.get("removeFailedDownloads") for x in new["download_clients"]): fail(f"{app} cleanup flags are unsafe")
        if new["queue"]!=old["queue"] or new["history"]!=old["history"]: fail(f"{app} queue or history changed")
    if now["arr"]["prowlarr"]["applications"]!=before["arr"]["prowlarr"]["applications"]: fail("Prowlarr applications changed")
    if [normalized_indexer(x) for x in now["arr"]["prowlarr"]["indexers"]]!=[normalized_indexer(x) for x in before["arr"]["prowlarr"]["indexers"]]: fail("Prowlarr indexer state drifted")
    for indexer in now["arr"]["prowlarr"]["indexers"]:
        if indexer.get("enable"):
            if (field(indexer,"torrentBaseSettings.seedRatio").get("value"),field(indexer,"torrentBaseSettings.seedTime").get("value"),field(indexer,"torrentBaseSettings.packSeedTime").get("value"))!=(1.0,1440,1440): fail("Prowlarr seed policy is incorrect")
    if now["bazarr"]!=before["bazarr"]: fail("Bazarr configuration or activity changed")
    if now["seerr"]!=before["seerr"]: fail("Seerr configuration or request state changed")
    validation_root=pathlib.Path(args.validation_root)
    incomplete_root=pathlib.Path(args.media_root).resolve()/"torrents/incomplete/.veinfin-download_lifecycle-validation"
    if validation_root.exists() or incomplete_root.exists(): fail("validation workspace remains")
    print("VERIFY=PASS TORRENTS=0 QUEUES=0 ARTIFACTS=0 POLICY=MatchAny/Stop HARDLINKS=ENABLED SYNTHETIC=DEFERRED")


def rollback_mode(args):
    before=protected_json(args.before); q=qbit(args); apps=clients(args)
    restore={k:before["qbit"]["preferences"].get(k) for k in PLANNED_PREFS}; q.set_preferences(restore)
    for app in ("sonarr","radarr"):
        for resource in before["arr"][app]["download_clients"]: apps[app].put(f"downloadclient/{resource['id']}",resource)
        config=before["arr"][app]["download_config"]; apps[app].put(f"config/downloadclient/{config['id']}",config)
    for resource in before["arr"]["prowlarr"]["indexers"]: apps["prowlarr"].put(f"indexer/{resource['id']}",resource)
    print("ROLLBACK=PASS MEDIA_UNTOUCHED=1")


def main():
    parser=argparse.ArgumentParser(); parser.add_argument("mode",choices=("validate-ssh","validate-policy","snapshot","backup","preview","apply-config","synthetic","cleanup-aborted","verify","rollback"))
    for name in ("policy","output","before","backup_dir","config_root","password_file","sonarr_key_file","radarr_key_file","prowlarr_key_file","bazarr_key_file","validation_root","media_root","report"): parser.add_argument("--"+name.replace("_","-"))
    parser.add_argument("--username"); parser.add_argument("--uid",type=int,default=0); parser.add_argument("--gid",type=int,default=0); args=parser.parse_args()
    if args.mode=="validate-ssh": validate_ssh_mode()
    elif args.mode=="validate-policy": policy(args.policy); print("POLICY=VALID")
    elif args.mode=="snapshot": snapshot_mode(args)
    elif args.mode=="backup": backup_mode(args)
    elif args.mode=="preview": planned_summary(args)
    elif args.mode=="apply-config": apply_config(args)
    elif args.mode=="synthetic": synthetic_mode(args)
    elif args.mode=="cleanup-aborted": cleanup_aborted_mode(args)
    elif args.mode=="verify": verify_mode(args)
    elif args.mode=="rollback": rollback_mode(args)


if __name__=="__main__":
    try: main()
    except (RuntimeError,ValueError,KeyError,OSError,urllib.error.URLError) as error:
        print(f"ERROR: {error}",file=sys.stderr); sys.exit(1)

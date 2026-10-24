#!/usr/bin/env python3
"""Protected Sonarr, Radarr, and Prowlarr API bootstrap for ARR deployment."""

import argparse
import http.cookiejar
import json
import os
import pathlib
import re
import secrets
import sys
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET


APPS = {
    "sonarr": (8989, "v3"),
    "radarr": (7878, "v3"),
    "prowlarr": (9696, "v1"),
}


def fail(message):
    raise RuntimeError(message)


def atomic_secret(path, value):
    path = pathlib.Path(path)
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(path.parent, 0o700)
    if path.exists():
        if path.is_symlink() or not path.is_file() or (path.stat().st_mode & 0o777) != 0o600:
            fail(f"unsafe existing secret file for {path.name}")
        if path.read_text().strip() != value:
            fail(f"existing {path.name} does not match application state")
        return
    temporary = path.parent / f".{path.name}.{secrets.token_hex(8)}"
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            stream.write(value + "\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if temporary.exists():
            temporary.unlink()


def capture_keys(config_root, secrets_root):
    keys = {}
    for name in APPS:
        config = pathlib.Path(config_root, name, "config.xml")
        if not config.is_file() or config.is_symlink():
            fail(f"{name} config.xml is missing or unsafe")
        key = ET.parse(config).getroot().findtext("ApiKey", "").lower()
        if len(key) != 32 or any(char not in "0123456789abcdef" for char in key):
            fail(f"{name} generated an invalid API key")
        atomic_secret(pathlib.Path(secrets_root, f"{name}-api-key"), key)
        keys[name] = key
    if len(set(keys.values())) != 3:
        fail("application API keys are not unique")
    return keys


class App:
    def __init__(self, name, api_key):
        self.name = name
        self.port, self.version = APPS[name]
        self.base = f"http://127.0.0.1:{self.port}/api/{self.version}"
        self.api_key = api_key

    def call(self, method, endpoint, body=None):
        data = None if body is None else json.dumps(body, separators=(",", ":")).encode()
        request = urllib.request.Request(
            f"{self.base}/{endpoint}", data=data, method=method,
            headers={"X-Api-Key": self.api_key, "Content-Type": "application/json"},
        )
        try:
            with urllib.request.urlopen(request, timeout=20) as response:
                raw = response.read()
                if response.status not in (200, 201, 202):
                    fail(f"{self.name} {endpoint} returned HTTP {response.status}")
                return json.loads(raw) if raw else None
        except urllib.error.HTTPError as error:
            detail = ""
            try:
                parsed = json.loads(error.read())
                if isinstance(parsed, list):
                    detail = "; ".join(
                        f"{item.get('propertyName', 'request')}: {item.get('errorMessage', 'rejected')}"
                        for item in parsed if isinstance(item, dict)
                    )
            except Exception:
                pass
            detail = re.sub(r"[0-9a-fA-F]{32,}", "[redacted]", detail)[:500]
            suffix = f": {detail}" if detail else ""
            fail(f"{self.name} API request failed for {endpoint} (HTTP {error.code}){suffix}")

    def get(self, endpoint):
        return self.call("GET", endpoint)

    def post(self, endpoint, body):
        return self.call("POST", endpoint, body)

    def put(self, endpoint, body):
        return self.call("PUT", endpoint, body)


def field_map(resource):
    return {field.get("name"): field for field in resource.get("fields", [])}


def set_fields(resource, values, required):
    fields = field_map(resource)
    missing = set(required) - set(fields)
    if missing:
        fail("verified API schema is missing required fields")
    for name, value in values.items():
        if name in fields:
            fields[name]["value"] = value


def configure_auth(app, username, password):
    host = app.get("config/host")
    host.update(
        authenticationMethod="forms",
        authenticationRequired="enabled",
        username=username,
        password=password,
        passwordConfirmation=password,
    )
    app.put(f"config/host/{host['id']}", host)


def ensure_roots(app, expected):
    roots = app.get("rootfolder")
    actual = {entry["path"].rstrip("/") for entry in roots}
    if not actual <= set(expected):
        fail(f"{app.name} has an unexpected root folder")
    for path in expected:
        if path not in actual:
            app.post("rootfolder", {"path": path})
    final = {entry["path"].rstrip("/") for entry in app.get("rootfolder")}
    if final != set(expected):
        fail(f"{app.name} root folders do not match")


def ensure_tag(app, label):
    matching = [tag for tag in app.get("tag") if tag.get("label") == label]
    if len(matching) > 1:
        fail("duplicate anime tags exist")
    return matching[0]["id"] if matching else app.post("tag", {"label": label})["id"]


def qbit_schema(app):
    schemas = [item for item in app.get("downloadclient/schema") if item.get("implementation") == "QBittorrent"]
    if len(schemas) != 1:
        fail(f"{app.name} qBittorrent schema is missing or ambiguous")
    return schemas[0]


def ensure_download_client(app, name, category, username, password, tags):
    clients = app.get("downloadclient")
    matching = [client for client in clients if client.get("name") == name]
    if len(matching) > 1:
        fail(f"duplicate {name} download clients exist")
    resource = qbit_schema(app)
    resource.update(
        name=name, enable=True, priority=1, tags=tags,
        removeCompletedDownloads=True, removeFailedDownloads=True,
    )
    category_field = "tvCategory" if app.name == "sonarr" else "movieCategory"
    values = {
        "host": "qbittorrent", "port": 8080, "useSsl": False, "urlBase": "",
        "username": username, "password": password, category_field: category,
        "tvImportedCategory": "", "movieImportedCategory": "",
    }
    set_fields(resource, values, {"host", "port", "useSsl", "username", "password", category_field})
    if matching:
        resource["id"] = matching[0]["id"]
    app.post("downloadclient/test", resource)
    if matching:
        app.put(f"downloadclient/{resource['id']}", resource)
    else:
        app.post("downloadclient", resource)


def configure_import_settings(app):
    completed = app.get("config/downloadclient")
    completed["enableCompletedDownloadHandling"] = True
    app.put(f"config/downloadclient/{completed['id']}", completed)
    media = app.get("config/mediamanagement")
    media["copyUsingHardlinks"] = True
    app.put(f"config/mediamanagement/{media['id']}", media)


def application_schema(prowlarr, implementation):
    schemas = [item for item in prowlarr.get("applications/schema") if item.get("implementation") == implementation]
    if len(schemas) != 1:
        fail(f"Prowlarr {implementation} schema is missing or ambiguous")
    return schemas[0]


def ensure_application(prowlarr, implementation, base_url, api_key):
    name = f"VeinFin {implementation}"
    applications = prowlarr.get("applications")
    matching = [application for application in applications if application.get("name") == name]
    if len(matching) > 1:
        fail(f"duplicate Prowlarr {implementation} applications exist")
    resource = application_schema(prowlarr, implementation)
    resource.update(name=name, enable=True, syncLevel="fullSync")
    set_fields(
        resource,
        {"prowlarrUrl": "http://prowlarr:9696", "baseUrl": base_url, "apiKey": api_key,
         "authUsername": "", "authPassword": ""},
        {"prowlarrUrl", "baseUrl", "apiKey"},
    )
    if matching:
        resource["id"] = matching[0]["id"]
    prowlarr.post("applications/test", resource)
    if matching:
        prowlarr.put(f"applications/{resource['id']}", resource)
    else:
        prowlarr.post("applications", resource)


def verify_login(name, username, password):
    port, version = APPS[name]
    base = f"http://127.0.0.1:{port}"
    try:
        urllib.request.urlopen(f"{base}/api/{version}/system/status", timeout=10)
        fail(f"{name} permits anonymous API access")
    except urllib.error.HTTPError as error:
        if error.code not in (401, 403):
            fail(f"{name} anonymous API returned unexpected HTTP {error.code}")

    def cookie_for(user, supplied_password):
        jar = http.cookiejar.CookieJar()
        opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))
        body = urllib.parse.urlencode(
            {"username": user, "password": supplied_password, "rememberMe": "false"}
        ).encode()
        try:
            opener.open(urllib.request.Request(f"{base}/login", data=body), timeout=10).read()
        except urllib.error.HTTPError:
            pass
        return list(jar)

    if not cookie_for(username, password):
        fail(f"{name} configured Forms login failed")
    if cookie_for("admin", "admin"):
        fail(f"{name} accepts default credentials")


def verify_download_clients(app, expected, username, password, anime_tag=None):
    clients = app.get("downloadclient")
    if {client["name"] for client in clients} != set(expected):
        fail(f"{app.name} download-client set is not exact")
    for client in clients:
        fields = {name: field.get("value") for name, field in field_map(client).items()}
        category = expected[client["name"]]
        category_field = "tvCategory" if app.name == "sonarr" else "movieCategory"
        if fields.get("host") != "qbittorrent" or int(fields.get("port", 0)) != 8080:
            fail(f"{app.name} download client does not use Docker DNS")
        if fields.get(category_field) != category or not client.get("enable") or not client.get("removeCompletedDownloads"):
            fail(f"{app.name} category/removal contract is incorrect")
        expected_tags = [anime_tag] if category == "anime" else []
        if client.get("tags", []) != expected_tags:
            fail(f"{app.name} download-client tag contract is incorrect")
        test_resource = qbit_schema(app)
        test_resource.update(
            name=client["name"], enable=True, priority=1, tags=client.get("tags", []),
            removeCompletedDownloads=True, removeFailedDownloads=True,
        )
        test_resource["id"] = client["id"]
        set_fields(
            test_resource,
            {"host": "qbittorrent", "port": 8080, "useSsl": False, "urlBase": "",
             "username": username, "password": password, category_field: category,
             "tvImportedCategory": "", "movieImportedCategory": ""},
            {"host", "port", "useSsl", "username", "password", category_field},
        )
        app.post("downloadclient/test", test_resource)


def verify_state(apps, keys, username, password):
    sonarr, radarr, prowlarr = apps["sonarr"], apps["radarr"], apps["prowlarr"]
    for app in apps.values():
        host = app.get("config/host")
        if host.get("authenticationMethod") != "forms" or host.get("authenticationRequired") != "enabled":
            fail(f"{app.name} does not require Forms authentication")
        if host.get("username") != username:
            fail(f"{app.name} management username does not match")
    sonarr_roots = {item["path"].rstrip("/") for item in sonarr.get("rootfolder")}
    radarr_roots = {item["path"].rstrip("/") for item in radarr.get("rootfolder")}
    if sonarr_roots != {"/data/library/tv", "/data/library/anime"}:
        fail("Sonarr root folders are not exact")
    if radarr_roots != {"/data/library/movies"}:
        fail("Radarr root folder is not exact")
    tags = [tag for tag in sonarr.get("tag") if tag.get("label") == "anime"]
    if len(tags) != 1:
        fail("Sonarr anime tag is missing or duplicated")
    verify_download_clients(
        sonarr,
        {"VeinFin qBittorrent TV": "tv", "VeinFin qBittorrent Anime": "anime"},
        username, password, tags[0]["id"],
    )
    verify_download_clients(radarr, {"VeinFin qBittorrent Movies": "movies"}, username, password)
    for app in (sonarr, radarr):
        if app.get("remotepathmapping") != []:
            fail(f"{app.name} has a remote path mapping")
        if not app.get("config/downloadclient").get("enableCompletedDownloadHandling"):
            fail(f"{app.name} completed-download handling is disabled")
        if not app.get("config/mediamanagement").get("copyUsingHardlinks"):
            fail(f"{app.name} hardlink imports are disabled")
    if sonarr.get("series") != [] or radarr.get("movie") != []:
        fail("a movie or series exists")
    applications = prowlarr.get("applications")
    if {item["name"] for item in applications} != {"VeinFin Sonarr", "VeinFin Radarr"}:
        fail("Prowlarr application set is not exact")
    for application in applications:
        fields = {name: field.get("value") for name, field in field_map(application).items()}
        expected = "http://sonarr:8989" if application["name"].endswith("Sonarr") else "http://radarr:7878"
        if fields.get("prowlarrUrl") != "http://prowlarr:9696" or fields.get("baseUrl") != expected:
            fail("Prowlarr application URL contract is incorrect")
        if not application.get("enable") or application.get("syncLevel") != "fullSync":
            fail("Prowlarr application synchronization contract is incorrect")
        implementation = "Sonarr" if application["name"].endswith("Sonarr") else "Radarr"
        service = implementation.lower()
        test_resource = application_schema(prowlarr, implementation)
        test_resource.update(name=application["name"], enable=True, syncLevel="fullSync")
        test_resource["id"] = application["id"]
        set_fields(
            test_resource,
            {"prowlarrUrl": "http://prowlarr:9696", "baseUrl": expected,
             "apiKey": keys[service], "authUsername": "", "authPassword": ""},
            {"prowlarrUrl", "baseUrl", "apiKey"},
        )
        prowlarr.post("applications/test", test_resource)
    if prowlarr.get("indexer") != []:
        fail("a Prowlarr indexer exists")


def main():
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("mode", choices=("apply", "verify", "capture"))
    parser.add_argument("--config-root", required=True)
    parser.add_argument("--secrets-root", required=True)
    parser.add_argument("--username", required=True)
    parser.add_argument("--password-file", required=True)
    args = parser.parse_args()
    password_path = pathlib.Path(args.password_file)
    if not password_path.is_file() or password_path.is_symlink() or (password_path.stat().st_mode & 0o777) != 0o600:
        fail("management password file is unsafe")
    password = password_path.read_text().rstrip("\r\n")
    if not password:
        fail("management password is empty")
    keys = capture_keys(args.config_root, args.secrets_root)
    print("PASS: three unique API keys are captured in protected files")
    if args.mode == "capture":
        return
    apps = {name: App(name, key) for name, key in keys.items()}
    if args.mode == "apply":
        for app in apps.values():
            configure_auth(app, args.username, password)
        ensure_roots(apps["sonarr"], ["/data/library/tv", "/data/library/anime"])
        ensure_roots(apps["radarr"], ["/data/library/movies"])
        anime_tag = ensure_tag(apps["sonarr"], "anime")
        ensure_download_client(apps["sonarr"], "VeinFin qBittorrent TV", "tv", args.username, password, [])
        ensure_download_client(apps["sonarr"], "VeinFin qBittorrent Anime", "anime", args.username, password, [anime_tag])
        ensure_download_client(apps["radarr"], "VeinFin qBittorrent Movies", "movies", args.username, password, [])
        configure_import_settings(apps["sonarr"])
        configure_import_settings(apps["radarr"])
        ensure_application(apps["prowlarr"], "Sonarr", "http://sonarr:8989", keys["sonarr"])
        ensure_application(apps["prowlarr"], "Radarr", "http://radarr:7878", keys["radarr"])
        print("PASS: authentication, roots, clients, hardlinks, and Prowlarr applications are configured")
    for name in APPS:
        verify_login(name, args.username, password)
    verify_state(apps, keys, args.username, password)
    print("PASS: API authentication and exact empty integration state are valid")


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"ERROR: {error}", file=sys.stderr)
        sys.exit(1)

#!/usr/bin/env python3
"""Secret-safe deterministic Media services application bootstrap and verification."""

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


def atomic_secret(path, value):
    path = pathlib.Path(path)
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(path.parent, 0o700)
    if path.exists():
        if not path.is_file() or path.is_symlink() or mode(path) != 0o600:
            fail(f"unsafe existing secret file: {path.name}")
        if read_secret(path) != value:
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


def request(method, url, body=None, headers=None, opener=None, form=False, allowed=(200, 201, 202, 204)):
    headers = dict(headers or {})
    if body is None:
        data = None
    elif form:
        data = urllib.parse.urlencode(body, doseq=True).encode()
        headers["Content-Type"] = "application/x-www-form-urlencoded"
    else:
        data = json.dumps(body, separators=(",", ":")).encode()
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, method=method, headers=headers)
    try:
        open_request = opener.open if opener is not None else urllib.request.urlopen
        with open_request(req, timeout=30) as response:
            raw = response.read()
            if response.status not in allowed:
                fail(f"request returned HTTP {response.status}")
            return json.loads(raw) if raw else None
    except urllib.error.HTTPError as error:
        fail(f"request failed for {urllib.parse.urlsplit(url).path} (HTTP {error.code})")


def jellyfin_login(username, password):
    headers = {"Authorization": 'MediaBrowser Client="VeinFin", Device="bootstrap", DeviceId="media_services", Version="1.0"'}
    result = request("POST", "http://127.0.0.1:8096/Users/AuthenticateByName", {"Username": username, "Pw": password}, headers)
    token = result.get("AccessToken", "")
    user = result.get("User", {})
    if not token or user.get("Name") != username or not user.get("Policy", {}).get("IsAdministrator"):
        fail("Jellyfin administrator authentication failed")
    return token


def jellyfin_bootstrap(username, password):
    public = request("GET", "http://127.0.0.1:8096/System/Info/Public")
    if not public.get("StartupWizardCompleted"):
        request("POST", "http://127.0.0.1:8096/Startup/Configuration", {
            "ServerName": "VeinFin", "UICulture": "en-US",
            "MetadataCountryCode": "SA", "PreferredMetadataLanguage": "en",
        })
        # Jellyfin 12 lazily creates its placeholder first user on this read.
        request("GET", "http://127.0.0.1:8096/Startup/User")
        request("POST", "http://127.0.0.1:8096/Startup/User", {"Name": username, "Password": password})
        request("POST", "http://127.0.0.1:8096/Startup/RemoteAccess", {
            "EnableRemoteAccess": True, "EnableAutomaticPortMapping": False,
        })
        request("POST", "http://127.0.0.1:8096/Startup/Complete", {})
    verify_jellyfin(username, password)


def verify_jellyfin(username, password):
    public = request("GET", "http://127.0.0.1:8096/System/Info/Public")
    if not public.get("StartupWizardCompleted") or public.get("ServerName") != "VeinFin":
        fail("Jellyfin startup or server-name contract is incomplete")
    token = jellyfin_login(username, password)
    headers = {"Authorization": f'MediaBrowser Client="VeinFin", Device="bootstrap", DeviceId="media_services", Version="1.0", Token="{token}"'}
    users = request("GET", "http://127.0.0.1:8096/Users", headers=headers)
    libraries = request("GET", "http://127.0.0.1:8096/Library/VirtualFolders", headers=headers)
    if len(users) != 1 or users[0].get("Name") != username or not users[0].get("Policy", {}).get("IsAdministrator"):
        fail("Jellyfin must contain exactly the intended administrator")
    if libraries != []:
        fail("Jellyfin has a configured library")
    try:
        request("GET", "http://127.0.0.1:8096/Users")
        fail("Jellyfin permits anonymous user enumeration")
    except RuntimeError as error:
        if "HTTP 401" not in str(error):
            raise


def xml_key(config_root, service):
    path = pathlib.Path(config_root, service, "config.xml")
    if not path.is_file() or path.is_symlink():
        fail(f"{service} configuration is unavailable")
    key = ET.parse(path).getroot().findtext("ApiKey", "").lower()
    if not re.fullmatch(r"[0-9a-f]{32}", key):
        fail(f"{service} API key is invalid")
    return key


def bazarr_key(config_root):
    path = pathlib.Path(config_root, "bazarr", "config", "config.yaml")
    if not path.is_file() or path.is_symlink():
        fail("Bazarr generated configuration is unavailable")
    in_auth = False
    for line in path.read_text(encoding="utf-8").splitlines():
        if line == "auth:":
            in_auth = True
            continue
        if in_auth and line and not line[0].isspace():
            break
        match = re.match(r"\s+apikey:\s*['\"]?([0-9a-fA-F]{32})['\"]?\s*$", line)
        if in_auth and match:
            return match.group(1).lower()
    fail("Bazarr API key was not found")


def bazarr_api(key, method, path, body=None, form=False):
    return request(method, "http://127.0.0.1:6767/api/" + path, body, {"X-API-KEY": key}, form=form)


def configure_bazarr(config_root, secrets_root, username, password, sonarr_key, radarr_key):
    key = bazarr_key(config_root)
    atomic_secret(pathlib.Path(secrets_root, "bazarr-api-key"), key)
    values = [
        ("settings-general-use_sonarr", "true"), ("settings-general-use_radarr", "true"),
        ("settings-sonarr-ip", "sonarr"), ("settings-sonarr-port", "8989"),
        ("settings-sonarr-base_url", "/"), ("settings-sonarr-ssl", "false"),
        ("settings-sonarr-apikey", sonarr_key), ("settings-sonarr-series_sync_on_live", "false"),
        ("settings-sonarr-full_update", "Manually"),
        ("settings-radarr-ip", "radarr"), ("settings-radarr-port", "7878"),
        ("settings-radarr-base_url", "/"), ("settings-radarr-ssl", "false"),
        ("settings-radarr-apikey", radarr_key), ("settings-radarr-movies_sync_on_live", "false"),
        ("settings-radarr-full_update", "Manually"),
        ("settings-auth-type", "form"), ("settings-auth-username", username),
        ("settings-auth-password", password),
    ]
    bazarr_api(key, "POST", "system/settings", values, form=True)
    verify_bazarr(key, username)


def verify_bazarr(key, username):
    data = bazarr_api(key, "GET", "system/settings")
    general, sonarr, radarr, auth = (data[name] for name in ("general", "sonarr", "radarr", "auth"))
    if not general.get("use_sonarr") or not general.get("use_radarr") or general.get("enabled_providers"):
        fail("Bazarr integration/provider state is incorrect")
    if (sonarr.get("ip"), int(sonarr.get("port", 0)), sonarr.get("base_url"), sonarr.get("ssl")) not in (("sonarr", 8989, "", False), ("sonarr", 8989, "/", False)):
        fail("Bazarr Sonarr connection is incorrect")
    if (radarr.get("ip"), int(radarr.get("port", 0)), radarr.get("base_url"), radarr.get("ssl")) not in (("radarr", 7878, "", False), ("radarr", 7878, "/", False)):
        fail("Bazarr Radarr connection is incorrect")
    if auth.get("type") != "form" or auth.get("username") != username or not auth.get("password"):
        fail("Bazarr form authentication is incomplete")
    for endpoint in ("episodes/wanted", "movies/wanted", "episodes/history", "movies/history"):
        result = bazarr_api(key, "GET", endpoint + "?start=0&length=1")
        if int(result.get("total", -1)) != 0:
            fail("Bazarr wanted/history state is not empty")


def seerr_session(username, password, initial):
    variants = [initial, False] if initial else [False]
    for include_server in variants:
        jar = http.cookiejar.CookieJar()
        opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))
        body = {"username": username, "password": password}
        if include_server:
            body.update(hostname="jellyfin", port=8096, useSsl=False, urlBase="", serverType=2, email=f"{username}@localhost")
        try:
            request("POST", "http://127.0.0.1:5055/api/v1/auth/jellyfin", body, opener=opener)
        except RuntimeError:
            if include_server:
                continue
            raise
        if list(jar):
            return opener
    fail("Seerr did not establish an authenticated session")


def seerr_call(opener, method, path, body=None):
    return request(method, "http://127.0.0.1:5055/api/v1/" + path, body, opener=opener)


def choose_profile(test_result):
    profiles = sorted(test_result.get("profiles", []), key=lambda item: (str(item.get("name", "")).lower(), int(item.get("id", 0))))
    if not profiles:
        fail("Seerr service test returned no quality profile")
    return profiles[0]


def configure_seerr(secrets_root, username, password, sonarr_key, radarr_key):
    public = request("GET", "http://127.0.0.1:5055/api/v1/settings/public")
    opener = seerr_session(username, password, not public.get("initialized"))
    main = seerr_call(opener, "GET", "settings/main")
    key = main.get("apiKey", "")
    if not re.fullmatch(r"[A-Za-z0-9+/_-]{32,128}={0,2}", key):
        fail("Seerr API key is invalid")
    atomic_secret(pathlib.Path(secrets_root, "seerr-api-key"), key)
    test_s = seerr_call(opener, "POST", "settings/sonarr/test", {"hostname": "sonarr", "port": 8989, "apiKey": sonarr_key, "useSsl": False, "baseUrl": ""})
    test_r = seerr_call(opener, "POST", "settings/radarr/test", {"hostname": "radarr", "port": 7878, "apiKey": radarr_key, "useSsl": False, "baseUrl": ""})
    if {x.get("path", "").rstrip("/") for x in test_s.get("rootFolders", [])} != {"/data/library/tv", "/data/library/anime"}:
        fail("Seerr did not observe exact Sonarr roots")
    if {x.get("path", "").rstrip("/") for x in test_r.get("rootFolders", [])} != {"/data/library/movies"}:
        fail("Seerr did not observe exact Radarr root")
    sp, rp = choose_profile(test_s), choose_profile(test_r)
    sonarr = {"name": "VeinFin Sonarr", "hostname": "sonarr", "port": 8989, "apiKey": sonarr_key,
              "useSsl": False, "baseUrl": "", "activeProfileId": sp["id"], "activeProfileName": sp["name"],
              "activeDirectory": "/data/library/tv", "activeAnimeProfileId": sp["id"],
              "activeAnimeProfileName": sp["name"], "activeAnimeDirectory": "/data/library/anime",
              "seriesType": "standard", "animeSeriesType": "anime", "tags": [], "animeTags": [],
              "is4k": False, "enableSeasonFolders": True, "isDefault": True,
              "externalUrl": "", "syncEnabled": False, "preventSearch": True,
              "tagRequests": False, "monitorNewItems": "all"}
    radarr = {"name": "VeinFin Radarr", "hostname": "radarr", "port": 7878, "apiKey": radarr_key,
              "useSsl": False, "baseUrl": "", "activeProfileId": rp["id"], "activeProfileName": rp["name"],
              "activeDirectory": "/data/library/movies", "is4k": False, "minimumAvailability": "released",
              "tags": [], "isDefault": True, "externalUrl": "", "syncEnabled": False,
              "preventSearch": True, "tagRequests": False}
    ensure_seerr_service(opener, "sonarr", sonarr)
    ensure_seerr_service(opener, "radarr", radarr)
    if not public.get("initialized"):
        seerr_call(opener, "POST", "settings/initialize")
    verify_seerr(opener)


def ensure_seerr_service(opener, kind, body):
    current = seerr_call(opener, "GET", f"settings/{kind}")
    matching = [item for item in current if item.get("name") == body["name"]]
    if len(current) > 1 or len(matching) > 1 or (current and not matching):
        fail(f"unexpected Seerr {kind} service exists")
    if matching:
        request("PUT", f"http://127.0.0.1:5055/api/v1/settings/{kind}/{matching[0]['id']}", body, opener=opener)
    else:
        seerr_call(opener, "POST", f"settings/{kind}", body)


def verify_seerr(opener):
    users = seerr_call(opener, "GET", "user?take=10&skip=0")
    requests = seerr_call(opener, "GET", "request?take=1&skip=0")
    if int(users.get("pageInfo", {}).get("results", -1)) != 1:
        fail("Seerr user set is not exactly one")
    if int(requests.get("pageInfo", {}).get("results", -1)) != 0:
        fail("Seerr contains a request")
    jelly = seerr_call(opener, "GET", "settings/jellyfin")
    if (jelly.get("ip"), int(jelly.get("port", 0)), jelly.get("useSsl"), jelly.get("urlBase")) != ("jellyfin", 8096, False, "") or any(item.get("enabled") for item in jelly.get("libraries", [])):
        fail("Seerr Jellyfin connection/library state is incorrect")
    expected = {"sonarr": ("sonarr", 8989, "/data/library/tv", "/data/library/anime"),
                "radarr": ("radarr", 7878, "/data/library/movies", None)}
    for kind, values in expected.items():
        items = seerr_call(opener, "GET", f"settings/{kind}")
        if len(items) != 1:
            fail(f"Seerr must contain exactly one {kind} connection")
        item = items[0]
        if (item.get("hostname"), int(item.get("port", 0)), item.get("activeDirectory"), item.get("activeAnimeDirectory")) != values:
            fail(f"Seerr {kind} connection is incorrect")
        if item.get("syncEnabled") or not item.get("preventSearch"):
            fail(f"Seerr {kind} scanning/search is not disabled")


class Arr:
    def __init__(self, name, key):
        self.name, self.key = name, key
        self.base = f"http://127.0.0.1:{9696 if name == 'prowlarr' else 8989 if name == 'sonarr' else 7878}/api/{'v1' if name == 'prowlarr' else 'v3'}"

    def call(self, method, endpoint, body=None):
        return request(method, f"{self.base}/{endpoint}", body, {"X-Api-Key": self.key})


def fields(resource):
    return {field.get("name"): field for field in resource.get("fields", [])}


def configure_proxy(prowlarr):
    tags = prowlarr.call("GET", "tag")
    matching_tags = [tag for tag in tags if tag.get("label") == "flaresolverr"]
    if len(matching_tags) > 1:
        fail("duplicate FlareSolverr tags exist")
    tag_id = matching_tags[0]["id"] if matching_tags else prowlarr.call("POST", "tag", {"label": "flaresolverr"})["id"]
    proxies = prowlarr.call("GET", "indexerProxy")
    matching = [item for item in proxies if item.get("name") == "FlareSolverr"]
    if len(proxies) > 1 or len(matching) > 1 or (proxies and not matching):
        fail("unexpected Prowlarr indexer proxy exists")
    schemas = [x for x in prowlarr.call("GET", "indexerProxy/schema") if x.get("implementation") == "FlareSolverr"]
    if len(schemas) != 1:
        fail("Prowlarr FlareSolverr schema is unavailable")
    resource = schemas[0]
    resource.update(name="FlareSolverr", enable=True, tags=[tag_id])
    fmap = fields(resource)
    if not {"host", "requestTimeout"} <= set(fmap):
        fail("Prowlarr FlareSolverr schema changed")
    fmap["host"]["value"] = "http://flaresolverr:8191"
    fmap["requestTimeout"]["value"] = 60
    if matching:
        resource["id"] = matching[0]["id"]
    prowlarr.call("POST", "indexerProxy/test", resource)
    if matching:
        prowlarr.call("PUT", f"indexerProxy/{resource['id']}", resource)
    else:
        prowlarr.call("POST", "indexerProxy", resource)
    verify_proxy(prowlarr)


def verify_proxy(prowlarr):
    tags = prowlarr.call("GET", "tag")
    wanted = [tag for tag in tags if tag.get("label") == "flaresolverr"]
    proxies = prowlarr.call("GET", "indexerProxy")
    if len(wanted) != 1 or len(proxies) != 1 or proxies[0].get("name") != "FlareSolverr" or proxies[0].get("tags") != [wanted[0]["id"]]:
        fail("Prowlarr FlareSolverr proxy/tag set is not exact")
    fmap = {name: field.get("value") for name, field in fields(proxies[0]).items()}
    if fmap.get("host", "").rstrip("/") != "http://flaresolverr:8191":
        fail("Prowlarr FlareSolverr URL is incorrect")
    if prowlarr.call("GET", "indexer") != []:
        fail("Prowlarr contains an indexer")


def main():
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("mode", choices=("jellyfin", "apply", "verify"))
    parser.add_argument("--config-root", required=True)
    parser.add_argument("--secrets-root", required=True)
    parser.add_argument("--username", required=True)
    parser.add_argument("--password-file", required=True)
    args = parser.parse_args()
    password = read_secret(args.password_file)
    if args.mode == "jellyfin":
        jellyfin_bootstrap(args.username, password)
        print("PASS: Jellyfin startup is complete with one administrator and zero libraries")
        return
    verify_jellyfin(args.username, password)
    keys = {name: read_secret(pathlib.Path(args.secrets_root, f"{name}-api-key")) for name in ("sonarr", "radarr", "prowlarr")}
    if args.mode == "apply":
        configure_bazarr(args.config_root, args.secrets_root, args.username, password, keys["sonarr"], keys["radarr"])
        configure_seerr(args.secrets_root, args.username, password, keys["sonarr"], keys["radarr"])
        configure_proxy(Arr("prowlarr", keys["prowlarr"]))
        print("PASS: Media services application integrations are configured")
    bazarr = read_secret(pathlib.Path(args.secrets_root, "bazarr-api-key"))
    seerr = read_secret(pathlib.Path(args.secrets_root, "seerr-api-key"))
    if len(set(keys.values()) | {bazarr, seerr}) != 5:
        fail("application API keys are not unique")
    verify_bazarr(bazarr, args.username)
    opener = seerr_session(args.username, password, False)
    verify_seerr(opener)
    verify_proxy(Arr("prowlarr", keys["prowlarr"]))
    print("PASS: Media services APIs, authentication, unique keys, and empty state are valid")


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"ERROR: {error}", file=sys.stderr)
        sys.exit(1)

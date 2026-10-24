#!/usr/bin/env python3
"""Credential-safe live smoke checks for the VeinFin control panel."""

import argparse
import http.cookiejar
import json
import ssl
import urllib.error
import urllib.request


EXPECTED = ["reverse-proxy", "jellyfin", "qbittorrent", "sonarr", "radarr", "prowlarr",
            "bazarr", "seerr", "flaresolverr", "recyclarr"]


def call(opener, connect_url, origin, path, method="GET", body=None, csrf=None, expected=(200,)):
    headers = {"Origin": origin, "Content-Type": "application/json"}
    if csrf: headers["X-CSRF-Token"] = csrf
    request = urllib.request.Request(connect_url + path, method=method, headers=headers,
                                     data=json.dumps(body or {}).encode() if method != "GET" else None)
    try:
        response = opener.open(request, timeout=30)
        status, raw = response.status, response.read()
    except urllib.error.HTTPError as error:
        status, raw = error.code, error.read()
    if status not in expected:
        raise RuntimeError(f"unexpected HTTP status for {path}: {status}")
    return status, json.loads(raw) if raw else {}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--origin", required=True)
    parser.add_argument("--connect-url", required=True)
    parser.add_argument("--username", required=True)
    parser.add_argument("--password-file", required=True)
    parser.add_argument("--action-service")
    parser.add_argument("--rate-limit-only", action="store_true")
    args = parser.parse_args()
    password = open(args.password_file, encoding="utf-8").read().strip()
    context = ssl.create_default_context(); context.check_hostname = False; context.verify_mode = ssl.CERT_NONE
    jar = http.cookiejar.CookieJar()
    opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar), urllib.request.HTTPSHandler(context=context))
    if args.rate_limit_only:
        for _ in range(5):
            call(opener, args.connect_url, args.origin, "/api/login", "POST", {"username": args.username, "password": "invalid"}, expected=(401,))
        call(opener, args.connect_url, args.origin, "/api/login", "POST", {"username": args.username, "password": "invalid"}, expected=(429,))
        print("PANEL_RATE_LIMIT=PASS")
        return
    call(opener, args.connect_url, args.origin, "/api/login", "POST", {"username": args.username, "password": "invalid"}, expected=(401,))
    _, login = call(opener, args.connect_url, args.origin, "/api/login", "POST", {"username": args.username, "password": password})
    csrf = login.get("csrf", "")
    if not csrf or sorted(item["id"] for item in login.get("services", [])) != sorted(EXPECTED):
        raise RuntimeError("service inventory or CSRF token is invalid")
    for item in login["services"]:
        if any(part in str(item.get("visit_url", "")) for part in ("@", "username=", "password=", "token=")):
            raise RuntimeError("credential-bearing Visit URL")
        for field in ("cpu_percent", "memory_bytes", "uptime_seconds"):
            if not isinstance(item.get(field), (int, float)) or item[field] < 0:
                raise RuntimeError("invalid service metric")
    call(opener, args.connect_url, args.origin, "/api/services/jellyfin/restart", "POST", {}, "wrong", expected=(403,))
    if args.action_service:
        _, result = call(opener, args.connect_url, args.origin, f"/api/services/{args.action_service}/restart", "POST", {}, csrf)
        selected = [item for item in result.get("services", []) if item["id"] == args.action_service]
        if len(selected) != 1 or not selected[0]["running"]:
            raise RuntimeError("controlled lifecycle action did not restore running state")
    call(opener, args.connect_url, args.origin, "/api/services/veinfin-panel/stop", "POST", {}, csrf, expected=(404,))
    call(opener, args.connect_url, args.origin, "/api/logout", "POST", {}, csrf)
    call(opener, args.connect_url, args.origin, "/api/session", expected=(401,))
    print("PANEL_SMOKE=PASS LOGIN=PASS INVALID=REJECTED CSRF=REJECTED LOGOUT=PASS INVENTORY=10")


if __name__ == "__main__":
    main()

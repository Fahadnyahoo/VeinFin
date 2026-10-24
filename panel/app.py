#!/usr/bin/env python3
"""VeinFin private panel or restricted Docker lifecycle agent."""

import base64
import hashlib
import hmac
import http.client
import json
import os
import re
import secrets
import socket
import ssl
import threading
import time
import urllib.parse
import urllib.error
import urllib.request
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SERVICES = {
    "reverse-proxy": {"name": "Caddy", "warning": True},
    "jellyfin": {"name": "Jellyfin", "warning": True},
    "qbittorrent": {"name": "qBittorrent"},
    "sonarr": {"name": "Sonarr"},
    "radarr": {"name": "Radarr"},
    "prowlarr": {"name": "Prowlarr"},
    "bazarr": {"name": "Bazarr"},
    "seerr": {"name": "Seerr"},
    "flaresolverr": {"name": "FlareSolverr"},
    "recyclarr": {"name": "Recyclarr", "on_demand": True},
}
ACTIONS = {"start", "stop", "restart"}
SERVICE_RE = re.compile(r"^[a-z][a-z0-9-]{0,31}$")


def read_secret(name):
    path = os.environ[name]
    value = open(path, encoding="utf-8").read().strip()
    if not value:
        raise RuntimeError(f"empty secret: {name}")
    return value


def json_bytes(value):
    return json.dumps(value, separators=(",", ":"), sort_keys=True).encode()


class UnixConnection(http.client.HTTPConnection):
    def __init__(self):
        super().__init__("localhost", timeout=8)

    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(self.timeout)
        self.sock.connect("/var/run/docker.sock")


def docker(method, path, allowed=(200, 201, 204, 304)):
    connection = UnixConnection()
    try:
        connection.request(method, path, headers={"Content-Length": "0"})
        response = connection.getresponse()
        data = response.read()
        if response.status not in allowed:
            raise RuntimeError(f"Docker operation failed with status {response.status}")
        return json.loads(data) if data else None
    finally:
        connection.close()


def container_name(service):
    if service not in SERVICES or not SERVICE_RE.fullmatch(service):
        raise ValueError("unsupported service")
    return f"/{os.environ.get('COMPOSE_PROJECT_NAME', 'veinfin')}-{service}-1"


def inspect_service(service):
    name = container_name(service)
    try:
        item = docker("GET", "/containers/" + urllib.parse.quote(name.lstrip("/")) + "/json")
    except RuntimeError as error:
        if "404" in str(error):
            item = None
        else:
            raise
    base = {"id": service, "name": SERVICES[service]["name"],
            "on_demand": SERVICES[service].get("on_demand", False),
            "warning": SERVICES[service].get("warning", False)}
    if item is None:
        return dict(base, exists=False, running=False, state="on-demand" if base["on_demand"] else "stopped",
                    health="not-created", cpu_percent=0.0, memory_bytes=0, uptime_seconds=0)
    labels = item.get("Config", {}).get("Labels", {})
    if (labels.get("com.docker.compose.project") != os.environ.get("COMPOSE_PROJECT_NAME", "veinfin")
            or labels.get("com.docker.compose.service") != service):
        raise RuntimeError("container identity failed allowlist validation")
    state = item.get("State", {})
    running = bool(state.get("Running"))
    health = state.get("Health", {}).get("Status", "none")
    uptime = 0
    if running and state.get("StartedAt"):
        try:
            from datetime import datetime, timezone
            started = datetime.fromisoformat(state["StartedAt"].replace("Z", "+00:00"))
            uptime = max(0, int((datetime.now(timezone.utc) - started).total_seconds()))
        except ValueError:
            uptime = 0
    cpu = 0.0
    memory = 0
    if running:
        stats = docker("GET", "/containers/" + urllib.parse.quote(name.lstrip("/")) + "/stats?stream=false")
        cpu_delta = stats.get("cpu_stats", {}).get("cpu_usage", {}).get("total_usage", 0) - stats.get("precpu_stats", {}).get("cpu_usage", {}).get("total_usage", 0)
        system_delta = stats.get("cpu_stats", {}).get("system_cpu_usage", 0) - stats.get("precpu_stats", {}).get("system_cpu_usage", 0)
        online = stats.get("cpu_stats", {}).get("online_cpus") or len(stats.get("cpu_stats", {}).get("cpu_usage", {}).get("percpu_usage", [])) or 1
        if cpu_delta > 0 and system_delta > 0:
            cpu = round(cpu_delta / system_delta * online * 100, 2)
        memory = max(0, int(stats.get("memory_stats", {}).get("usage", 0)) - int(stats.get("memory_stats", {}).get("stats", {}).get("inactive_file", 0)))
    return dict(base, exists=True, running=running, state=state.get("Status", "unknown"),
                health=health, cpu_percent=cpu, memory_bytes=memory, uptime_seconds=uptime)


AGENT_LOCKS = {name: threading.Lock() for name in SERVICES}


class CommonHandler(BaseHTTPRequestHandler):
    server_version = "VeinFin"

    def log_message(self, fmt, *args):
        print(f"{self.command} {self.path.split('?', 1)[0]} {args[1] if len(args) > 1 else '-'}", flush=True)

    def send_json(self, status, value, headers=None):
        body = json_bytes(value)
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Referrer-Policy", "no-referrer")
        for key, value in (headers or {}).items():
            self.send_header(key, value)
        self.end_headers()
        self.wfile.write(body)

    def read_json(self):
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            raise ValueError("invalid request length")
        if length < 0 or length > 16384:
            raise ValueError("invalid request length")
        try:
            return json.loads(self.rfile.read(length)) if length else {}
        except json.JSONDecodeError:
            raise ValueError("invalid JSON")


class AgentHandler(CommonHandler):
    def authorized(self):
        expected = "Bearer " + self.server.agent_secret
        return hmac.compare_digest(self.headers.get("Authorization", ""), expected)

    def route(self):
        match = re.fullmatch(r"/v1/services/([a-z0-9-]+)(?:/(start|stop|restart))?", self.path)
        if not match or match.group(1) not in SERVICES:
            self.send_json(HTTPStatus.NOT_FOUND, {"error": "not found"}); return None
        return match.groups()

    def do_GET(self):
        if self.path == "/healthz":
            self.send_json(HTTPStatus.OK, {"status": "ok"}); return
        if not self.authorized():
            self.send_json(HTTPStatus.UNAUTHORIZED, {"error": "unauthorized"}); return
        if self.path == "/v1/services":
            self.send_json(HTTPStatus.OK, {"services": [inspect_service(name) for name in SERVICES]}); return
        route = self.route()
        if route and not route[1]:
            self.send_json(HTTPStatus.OK, inspect_service(route[0]))

    def do_POST(self):
        if not self.authorized():
            self.send_json(HTTPStatus.UNAUTHORIZED, {"error": "unauthorized"}); return
        route = self.route()
        if not route or route[1] not in ACTIONS:
            return
        service, action = route
        with AGENT_LOCKS[service]:
            current = inspect_service(service)
            if not current["exists"]:
                self.send_json(HTTPStatus.CONFLICT, {"error": "service container does not exist"}); return
            endpoint = urllib.parse.quote(container_name(service).lstrip("/"))
            if action == "start" and not current["running"]:
                docker("POST", f"/containers/{endpoint}/start")
            elif action == "stop" and current["running"]:
                docker("POST", f"/containers/{endpoint}/stop?t=15")
            elif action == "restart":
                docker("POST", f"/containers/{endpoint}/restart?t=15")
            deadline = time.monotonic() + 20
            resulting = inspect_service(service)
            while time.monotonic() < deadline and action in {"start", "restart"} and not resulting["running"]:
                time.sleep(0.25); resulting = inspect_service(service)
            self.send_json(HTTPStatus.OK, {"ok": True, "service": resulting})


HTML = r'''<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>VeinFin</title><style>
:root{color-scheme:light dark;--bg:#f4f6f8;--card:#fff;--fg:#18202a;--muted:#627080;--line:#d8dee6;--ok:#18864b;--warn:#bd7b00;--bad:#c83c42;--accent:#4969ed} @media(prefers-color-scheme:dark){:root{--bg:#101419;--card:#1a2028;--fg:#eef3f8;--muted:#9aa8b7;--line:#303a46;--ok:#42c77a;--warn:#f0ad35;--bad:#ff6b70;--accent:#8399ff}}*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);font:15px system-ui,sans-serif}main{max-width:1100px;margin:auto;padding:24px}header{display:flex;justify-content:space-between;align-items:center}h1{font-size:24px}.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(255px,1fr));gap:14px}.card{background:var(--card);border:1px solid var(--line);border-radius:14px;padding:16px}.row{display:flex;justify-content:space-between;gap:10px;align-items:center}.dot{width:10px;height:10px;border-radius:50%;display:inline-block;background:var(--bad)}.dot.ok{background:var(--ok)}.dot.warn{background:var(--warn)}.meta{color:var(--muted);line-height:1.7;margin:10px 0}.actions{display:flex;flex-wrap:wrap;gap:7px}button,.visit{border:1px solid var(--line);background:transparent;color:var(--fg);padding:8px 11px;border-radius:8px;cursor:pointer;text-decoration:none}button.primary{background:var(--accent);color:white;border-color:var(--accent)}button:disabled{opacity:.45;cursor:not-allowed}.login{max-width:360px;margin:12vh auto}.login input{width:100%;padding:11px;margin:6px 0 12px;border:1px solid var(--line);border-radius:8px;background:var(--card);color:var(--fg)}#notice{position:fixed;right:18px;bottom:18px;max-width:360px;padding:12px 16px;border-radius:10px;background:var(--card);border:1px solid var(--line);display:none}.error{color:var(--bad)}small{color:var(--muted)}</style></head><body><main><section id="login" class="login"><h1>VeinFin</h1><p>Private management panel</p><form id="loginForm"><label>Username<input name="username" autocomplete="username" required></label><label>Password<input name="password" type="password" autocomplete="current-password" required></label><button class="primary" type="submit">Sign in</button></form><p id="loginError" class="error"></p></section><section id="dashboard" hidden><header><div><h1>VeinFin</h1><small>Private service management</small></div><button id="logout">Log out</button></header><p id="refreshed"></p><div id="cards" class="grid"></div></section></main><div id="notice"></div><script>
let csrf='',busy=false;const $=s=>document.querySelector(s),fmtBytes=n=>n<1048576?(n/1024).toFixed(1)+' KiB':(n/1048576).toFixed(1)+' MiB',fmtTime=n=>{let d=Math.floor(n/86400),h=Math.floor(n%86400/3600),m=Math.floor(n%3600/60);return `${d}d ${h}h ${m}m`};function notice(msg,bad=false){let n=$('#notice');n.textContent=msg;n.className=bad?'error':'';n.style.display='block';setTimeout(()=>n.style.display='none',3500)}async function api(path,opt={}){opt.headers={...(opt.headers||{}),'Content-Type':'application/json'};if(csrf)opt.headers['X-CSRF-Token']=csrf;let r=await fetch(path,opt);let j=await r.json().catch(()=>({error:'Invalid response'}));if(!r.ok)throw Error(j.error||'Request failed');return j}function button(label,service,action,disabled=false){let b=document.createElement('button');b.textContent=label;b.disabled=disabled;b.onclick=()=>act(service,action);return b}function render(data){let root=$('#cards');root.replaceChildren();for(const s of data.services){let c=document.createElement('article');c.className='card';let head=document.createElement('div');head.className='row';let title=document.createElement('strong');title.textContent=s.name;let state=document.createElement('span');let dot=document.createElement('i');dot.className='dot '+(s.running?(s.health==='healthy'||s.health==='none'?'ok':'warn'):(s.on_demand?'warn':''));state.append(dot,' '+s.state);head.append(title,state);let meta=document.createElement('div');meta.className='meta';meta.textContent=s.on_demand&&!s.exists?'On-demand · not currently created':`Health: ${s.health}\nCPU: ${s.cpu_percent.toFixed(2)}% · Memory: ${fmtBytes(s.memory_bytes)}\nUptime: ${fmtTime(s.uptime_seconds)}`;meta.style.whiteSpace='pre-line';let a=document.createElement('div');a.className='actions';a.append(button('Start',s.id,'start',s.running||!s.exists),button('Stop',s.id,'stop',!s.running),button('Restart',s.id,'restart',!s.running));if(s.visit_url){let v=document.createElement('a');v.className='visit';v.textContent='Visit';v.href=s.visit_url;v.target='_blank';v.rel='noopener noreferrer';a.append(v)}c.append(head,meta,a);root.append(c)}$('#refreshed').textContent='Updated '+new Date().toLocaleTimeString()}async function refresh(){if(busy)return;try{render(await api('/api/services'))}catch(e){if(e.message==='unauthorized'){showLogin()}else notice(e.message,true)}}async function act(service,action){if(action==='stop'||action==='restart'){let critical=service==='jellyfin'||service==='reverse-proxy';if(!confirm(critical?`Confirm ${action} of this critical service?`:`Confirm ${action}?`))return}busy=true;try{let j=await api(`/api/services/${encodeURIComponent(service)}/${action}`,{method:'POST',body:'{}'});render({services:j.services});notice(`${action} completed`)}catch(e){notice(e.message,true)}finally{busy=false}}function showLogin(){$('#dashboard').hidden=true;$('#login').hidden=false;csrf=''}$('#loginForm').onsubmit=async e=>{e.preventDefault();let f=new FormData(e.target);try{let j=await api('/api/login',{method:'POST',body:JSON.stringify({username:f.get('username'),password:f.get('password')})});csrf=j.csrf;$('#login').hidden=true;$('#dashboard').hidden=false;render(j);e.target.reset()}catch(x){$('#loginError').textContent=x.message}};$('#logout').onclick=async()=>{try{await api('/api/logout',{method:'POST',body:'{}'})}finally{showLogin()}};(async()=>{try{let j=await api('/api/session');csrf=j.csrf;$('#login').hidden=true;$('#dashboard').hidden=false;await refresh();setInterval(refresh,10000)}catch(e){showLogin()}})();
</script></body></html>'''


class PanelHandler(CommonHandler):
    sessions = {}
    failures = {}
    lock = threading.Lock()

    def security_headers(self):
        return {"Content-Security-Policy": "default-src 'self'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'",
                "Strict-Transport-Security": "max-age=31536000"}

    def origin_ok(self):
        return self.headers.get("Origin", "") == self.server.origin

    def cookie(self):
        for item in self.headers.get("Cookie", "").split(";"):
            key, _, value = item.strip().partition("=")
            if key == "__Host-veinfin": return value
        return ""

    def session(self):
        token = self.cookie()
        session_id, separator, signature = token.partition(".")
        expected = hmac.new(self.server.session_secret.encode(), session_id.encode(), hashlib.sha256).hexdigest()
        if not separator or not hmac.compare_digest(signature, expected):
            return None
        with self.lock:
            record = self.sessions.get(session_id)
            if not record or record["expires"] <= time.time():
                self.sessions.pop(session_id, None); return None
            record["expires"] = time.time() + self.server.session_seconds
            return record

    def require_session(self, csrf=False):
        record = self.session()
        if not record:
            self.send_json(HTTPStatus.UNAUTHORIZED, {"error": "unauthorized"}, self.security_headers()); return None
        if csrf and (not self.origin_ok() or not hmac.compare_digest(self.headers.get("X-CSRF-Token", ""), record["csrf"])):
            self.send_json(HTTPStatus.FORBIDDEN, {"error": "CSRF validation failed"}, self.security_headers()); return None
        return record

    def agent(self, method, path):
        request = urllib.request.Request("http://agent:9000" + path, method=method,
            headers={"Authorization": "Bearer " + self.server.agent_secret, "Content-Length": "0"})
        try:
            with urllib.request.urlopen(request, timeout=25) as response:
                return json.loads(response.read())
        except urllib.error.HTTPError as error:
            try: message = json.loads(error.read()).get("error", "agent request failed")
            except (ValueError, AttributeError): message = "agent request failed"
            raise RuntimeError(message)

    def add_visits(self, value):
        for item in value["services"]:
            item["visit_url"] = self.server.visits.get(item["id"])
        return value

    def do_GET(self):
        if self.path == "/healthz":
            self.send_json(HTTPStatus.OK, {"status": "ok"}, self.security_headers()); return
        if self.path == "/":
            body = HTML.encode()
            self.send_response(HTTPStatus.OK)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            for key, value in self.security_headers().items(): self.send_header(key, value)
            self.send_header("X-Content-Type-Options", "nosniff"); self.send_header("X-Frame-Options", "DENY")
            self.end_headers(); self.wfile.write(body); return
        if self.path == "/api/session":
            record = self.require_session()
            if record: self.send_json(HTTPStatus.OK, {"csrf": record["csrf"]}, self.security_headers())
            return
        if self.path == "/api/services":
            if self.require_session(): self.send_json(HTTPStatus.OK, self.add_visits(self.agent("GET", "/v1/services")), self.security_headers())
            return
        self.send_json(HTTPStatus.NOT_FOUND, {"error": "not found"}, self.security_headers())

    def do_POST(self):
        if self.path == "/api/login":
            if not self.origin_ok():
                self.send_json(HTTPStatus.FORBIDDEN, {"error": "origin rejected"}, self.security_headers()); return
            peer = self.client_address[0]
            now = time.time()
            with self.lock:
                attempts = [value for value in self.failures.get(peer, []) if value > now - 60]
                self.failures[peer] = attempts
            if len(attempts) >= 5:
                self.send_json(HTTPStatus.TOO_MANY_REQUESTS, {"error": "too many login attempts"}, self.security_headers()); return
            try: payload = self.read_json()
            except ValueError as error:
                self.send_json(HTTPStatus.BAD_REQUEST, {"error": str(error)}, self.security_headers()); return
            valid = hmac.compare_digest(str(payload.get("username", "")), self.server.username) and verify_password(str(payload.get("password", "")), self.server.password_hash)
            if not valid:
                with self.lock: self.failures.setdefault(peer, []).append(now)
                self.send_json(HTTPStatus.UNAUTHORIZED, {"error": "invalid credentials"}, self.security_headers()); return
            session_id, csrf = secrets.token_urlsafe(32), secrets.token_urlsafe(32)
            with self.lock:
                self.failures.pop(peer, None); self.sessions[session_id] = {"csrf": csrf, "expires": now + self.server.session_seconds}
            value = self.add_visits(self.agent("GET", "/v1/services")); value["csrf"] = csrf
            signature = hmac.new(self.server.session_secret.encode(), session_id.encode(), hashlib.sha256).hexdigest()
            token = session_id + "." + signature
            cookie = f"__Host-veinfin={token}; Path=/; HttpOnly; Secure; SameSite=Strict; Max-Age={self.server.session_seconds}"
            self.send_json(HTTPStatus.OK, value, {**self.security_headers(), "Set-Cookie": cookie}); return
        if self.path == "/api/logout":
            if not self.require_session(csrf=True): return
            session_id = self.cookie().partition(".")[0]
            with self.lock: self.sessions.pop(session_id, None)
            self.send_json(HTTPStatus.OK, {"ok": True}, {**self.security_headers(), "Set-Cookie": "__Host-veinfin=; Path=/; HttpOnly; Secure; SameSite=Strict; Max-Age=0"}); return
        match = re.fullmatch(r"/api/services/([a-z0-9-]+)/(start|stop|restart)", self.path)
        if match:
            if not self.require_session(csrf=True): return
            service, action = match.groups()
            if service not in SERVICES:
                self.send_json(HTTPStatus.NOT_FOUND, {"error": "unsupported service"}, self.security_headers()); return
            result = self.agent("POST", f"/v1/services/{service}/{action}")
            value = self.add_visits(self.agent("GET", "/v1/services")); value["result"] = result
            self.send_json(HTTPStatus.OK, value, self.security_headers()); return
        self.send_json(HTTPStatus.NOT_FOUND, {"error": "not found"}, self.security_headers())


def verify_password(password, encoded):
    try:
        prefix, iterations, salt, expected = encoded.split("$")
        if prefix != "pbkdf2-sha256" or int(iterations) < 600000: return False
        actual = hashlib.pbkdf2_hmac("sha256", password.encode(), base64.urlsafe_b64decode(salt), int(iterations), dklen=32)
        return hmac.compare_digest(actual, base64.urlsafe_b64decode(expected))
    except (ValueError, TypeError):
        return False


def main():
    mode = os.environ.get("VEINFIN_PANEL_MODE")
    if mode == "agent":
        server = ThreadingHTTPServer(("0.0.0.0", 9000), AgentHandler)
        server.agent_secret = read_secret("AGENT_SECRET_FILE")
    elif mode == "panel":
        server = ThreadingHTTPServer(("0.0.0.0", 3000), PanelHandler)
        server.agent_secret = read_secret("AGENT_SECRET_FILE")
        server.password_hash = read_secret("PASSWORD_HASH_FILE")
        server.session_secret = read_secret("SESSION_SECRET_FILE")
        server.username = os.environ["MANAGEMENT_USERNAME"]
        server.origin = os.environ["PANEL_ORIGIN"]
        server.visits = json.loads(os.environ["VISIT_URLS_JSON"])
        server.session_seconds = int(os.environ.get("SESSION_SECONDS", "28800"))
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.minimum_version = ssl.TLSVersion.TLSv1_2
        context.load_cert_chain(os.environ["TLS_CERT_FILE"], os.environ["TLS_KEY_FILE"])
        server.socket = context.wrap_socket(server.socket, server_side=True)
    else:
        raise RuntimeError("VEINFIN_PANEL_MODE must be panel or agent")
    server.serve_forever()


if __name__ == "__main__":
    main()

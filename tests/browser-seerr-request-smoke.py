#!/usr/bin/env python3
"""Prove unavailable Seerr cards expose Request controls without submitting one."""

import json
import sys
import time
import urllib.error
import urllib.request

ENDPOINT = "http://127.0.0.1:4444"
ELEMENT = "element-6066-11e4-a52e-4f735466cecf"


def request(method, path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    call = urllib.request.Request(ENDPOINT + path, data=data, method=method,
                                  headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(call, timeout=60) as response:
            return json.loads(response.read() or b"{}").get("value")
    except urllib.error.HTTPError as error:
        raise RuntimeError(f"WebDriver returned HTTP {error.code}") from error


def main():
    base, username, password = [sys.stdin.readline().rstrip("\r\n") for _ in range(3)]
    if not all((base, username, password)):
        raise RuntimeError("browser inputs are incomplete")
    session = request("POST", "/session", {
        "capabilities": {"alwaysMatch": {"browserName": "safari"}},
    })["sessionId"]
    root = f"/session/{session}"

    def execute(script, args=None, asynchronous=False):
        mode = "async" if asynchronous else "sync"
        return request("POST", root + f"/execute/{mode}", {"script": script, "args": args or []})

    def find(selector):
        try:
            return request("POST", root + "/element", {
                "using": "css selector", "value": selector,
            })[ELEMENT]
        except (RuntimeError, TypeError):
            return None

    def send(element, value):
        request("POST", root + f"/element/{element}/value", {"text": value, "value": list(value)})

    try:
        request("POST", root + "/url", {"url": base.rstrip("/") + "/web/"})
        for _ in range(60):
            name = find("#txtManualName") or find("input[autocomplete='username']")
            secret = find("#txtManualPassword") or find("input[type='password']")
            if name and secret:
                break
            time.sleep(0.5)
        else:
            raise RuntimeError("login controls did not appear")
        send(name, username)
        send(secret, password)
        button = find("#btnManualLogin") or find("button[type='submit']")
        execute("arguments[0].click();return true", [{ELEMENT: button}])
        for _ in range(80):
            if execute("return !!window.ApiClient&&!!window.ApiClient.accessToken()&&!location.hash.includes('login')"):
                break
            time.sleep(0.5)
        else:
            raise RuntimeError("browser authentication did not complete")
        request("POST", root + "/url", {"url": base.rstrip("/") + "/web/#/search.html"})
        time.sleep(4)
        result = execute("""
const done=arguments[arguments.length-1];
Promise.all([
  JellyfinEnhanced.jellyseerrAPI.checkUserStatus(),
  JellyfinEnhanced.jellyseerrAPI.search('the',1)
]).then(([user,response])=>{
  const unavailable=(response.results||[]).filter(item=>
    !item.mediaInfo&&(item.mediaType==='movie'||item.mediaType==='tv'));
  JellyfinEnhanced.jellyseerrUI.renderJellyseerrResults(
    unavailable,'the',false,user.active,user.userFound);
  const locate=type=>{
    const tagged=document.querySelector(`.jellyseerr-card [data-media-type="${type}"]`)
      ||document.querySelector(`.jellyseerr-card[data-media-type="${type}"]`);
    return tagged&&(tagged.closest('.jellyseerr-card')||tagged);
  };
  setTimeout(()=>{
    ['movie','tv'].forEach(type=>{
      const target=locate(type)?.querySelector('.jellyseerr-poster-image');
      target?.dispatchEvent(new KeyboardEvent('keydown',{
        key:'Enter',code:'Enter',bubbles:true,view:window
      }));
    });
    setTimeout(()=>{
      const check=type=>{
        const card=locate(type);
        const control=card?.querySelector('.jellyseerr-request-button');
        return !!control&&control.classList.contains('jellyseerr-button-request')
          &&!control.disabled&&getComputedStyle(control).display!=='none';
      };
      done({movie:check('movie'),show:check('tv')});
    },1000);
  },600);
}).catch(()=>done({movie:false,show:false}));
""", asynchronous=True)
        if result != {"movie": True, "show": True}:
            raise RuntimeError("enabled movie/show Request controls were not rendered")
        execute("const done=arguments[arguments.length-1];ApiClient.logout().then(()=>done(true)).catch(()=>done(false))",
                asynchronous=True)
        print("PASS: unavailable movie and show Request controls rendered; no request submitted")
    finally:
        try:
            request("DELETE", root)
        except Exception:
            pass


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"FAIL: {error}", file=sys.stderr)
        raise SystemExit(1)

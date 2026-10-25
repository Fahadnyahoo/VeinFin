#!/usr/bin/env python3
"""Public Safari smoke test. Reads URL, username, password, item id from stdin."""

import base64
import json
import os
from pathlib import Path
import sys
import time
import urllib.error
import urllib.request

ENDPOINT = "http://127.0.0.1:4444"
ELEMENT = "element-6066-11e4-a52e-4f735466cecf"


def request(method, path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(ENDPOINT + path, data=data, method=method,
                                 headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=60) as response:
            result = json.loads(response.read() or b"{}")
    except urllib.error.HTTPError as error:
        raw = error.read()
        try:
            detail = json.loads(raw or b"{}").get("value", {})
            message = detail.get("message") or detail.get("error") or raw.decode(errors="replace")
        except (ValueError, AttributeError):
            message = raw.decode(errors="replace")
        raise RuntimeError(f"WebDriver {method} {path} returned HTTP {error.code}: {message}") from error
    value = result.get("value")
    if isinstance(value, dict) and value.get("error"):
        raise RuntimeError(value.get("message", value["error"]))
    return value


def wait_for(test, timeout=30, label="condition"):
    deadline = time.time() + timeout
    last = None
    while time.time() < deadline:
        try:
            value = test()
            if value:
                return value
        except (RuntimeError, urllib.error.URLError) as error:
            last = error
        time.sleep(0.5)
    raise RuntimeError(f"browser wait timed out at {label}: {last or 'condition not met'}")


def main():
    values = [sys.stdin.readline().rstrip("\r\n") for _ in range(4)]
    if any(not value for value in values):
        raise RuntimeError("browser inputs are incomplete")
    base, username, password, item_id = values
    legacy = os.environ.get("VEINFIN_LEGACY_UI") == "1"
    capture_only = os.environ.get("VEINFIN_BROWSER_CAPTURE_ONLY") == "1"
    screenshot_prefix = os.environ.get("VEINFIN_BROWSER_SCREENSHOT_PREFIX", "candidate")
    screenshot_dir = os.environ.get("VEINFIN_BROWSER_SCREENSHOT_DIR", "")
    session = request("POST", "/session", {"capabilities": {"alwaysMatch": {"browserName": "safari"}}})["sessionId"]
    root = f"/session/{session}"
    stage = "session setup"

    def execute(script, args=None):
        return request("POST", root + "/execute/sync", {"script": script, "args": args or []})

    def execute_async(script, args=None):
        return request("POST", root + "/execute/async", {"script": script, "args": args or []})

    def find(selector):
        return request("POST", root + "/element", {"using": "css selector", "value": selector})[ELEMENT]

    def find_any(selectors):
        for selector in selectors:
            try:
                candidate = execute("return [...document.querySelectorAll(arguments[0])].find(x=>x.offsetParent!==null)||null", [selector])
                if candidate:
                    return candidate[ELEMENT]
            except Exception:
                pass
        return None

    def click(element):
        try:
            request("POST", root + f"/element/{element}/click", {})
        except RuntimeError as error:
            if not any(message in str(error) for message in ("click intercepted", "element not interactable")):
                raise
            execute("arguments[0].click();return true", [{ELEMENT: element}])

    def send(element, value):
        request("POST", root + f"/element/{element}/clear", {})
        request("POST", root + f"/element/{element}/value", {"text": value, "value": list(value)})

    def screenshot(name):
        if not screenshot_dir:
            return
        target_dir = Path(screenshot_dir)
        target_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
        target = target_dir / f"{screenshot_prefix}-{name}.png"
        target.write_bytes(base64.b64decode(request("GET", root + "/screenshot")))
        target.chmod(0o600)

    def login():
        try:
            name = wait_for(lambda: find_any(("#txtManualName", "input[autocomplete='username']")), 8, "username")
        except RuntimeError as error:
            diagnostic = execute("return {hash:location.hash,bodyId:document.body.id,inputs:[...document.querySelectorAll('input')].filter(x=>x.offsetParent).map(x=>({type:x.type,id:x.id,name:x.name,cls:x.className,autocomplete:x.autocomplete})),controls:[...document.querySelectorAll('button,a')].filter(x=>x.offsetParent).slice(0,12).map(x=>({tag:x.tagName,id:x.id,cls:x.className}))}")
            raise RuntimeError(f"{error}; safe state={diagnostic}")
        secret = wait_for(lambda: find_any(("#txtManualPassword", "input[type='password']")), label="password")
        send(name, username); send(secret, password)
        click(wait_for(lambda: find_any(("#btnManualLogin", "button[type='submit']")), label="login button"))
        time.sleep(1.5)
        if not execute("return !!window.ApiClient && !!window.ApiClient.accessToken()"):
            request("POST", root + f"/element/{secret}/value", {"text": "\ue007", "value": ["\ue007"]})
        try:
            wait_for(lambda: execute("return !!window.ApiClient && !!window.ApiClient.accessToken() && !location.hash.includes('login') && !location.hash.includes('selectserver')"), 40, "authenticated client")
        except RuntimeError as error:
            diagnostic = execute("const u=document.querySelector('#txtManualName,input[autocomplete=username]'),p=document.querySelector('#txtManualPassword,input[type=password]'),b=document.querySelector('#btnManualLogin,button[type=submit]');return {hash:location.hash,api:!!window.ApiClient,password:!!p,userLength:(u&&u.value||'').length,passwordLength:(p&&p.value||'').length,buttonDisabled:!!(b&&b.disabled),errors:[...document.querySelectorAll('.fieldDescriptionError:not(.hide),.errorMessage:not(.hide)')].filter(x=>x.offsetParent!==null).map(x=>x.textContent.trim()).filter(Boolean).slice(0,3)}")
            raise RuntimeError(f"{error}; safe state={diagnostic}")

    try:
        stage = "desktop viewport"
        request("POST", root + "/window/rect", {"width": 1365, "height": 900, "x": 0, "y": 0})
        stage = "initial navigation"
        request("POST", root + "/url", {"url": base + "/web/"})
        stage = "initial login"
        login()
        request("POST", root + "/url", {"url": base + "/web/#/home"})
        stage = "home validation"
        execute("window.__veinfinErrors=[];addEventListener('error',e=>window.__veinfinErrors.push({message:String(e.message||e.error||'error'),source:String(e.filename||'')}),true);addEventListener('unhandledrejection',e=>window.__veinfinErrors.push({message:String(e.reason||'rejection'),source:''}),true);return true")
        home = wait_for(lambda: execute("return document.querySelectorAll('.homeSectionsContainer,.verticalSection,.itemsContainer').length"), 30, "home sections")
        if home < 1:
            raise RuntimeError("home page sections did not render")
        dark = execute("const c=getComputedStyle(document.body).backgroundColor.match(/\\d+/g);return c&&c.slice(0,3).reduce((a,n)=>a+Number(n),0)<300")
        if not dark:
            raise RuntimeError("dark client theme is not active")
        plugin_state = execute("return {kefinConfig:!!window.KefinTweaksConfig,kefin:!!window.KefinTweaks,enhanced:!!window.JellyfinEnhanced,mediaBar:!!window.mediaBarEnhancedLoaded,homeSections:!!window.HssPageMeta,cinematic:[...document.styleSheets].some(x=>(x.href||'').includes('veinfin-cinematic.css')),hero:!!document.querySelector('#slides-container,.spotlight-section')}" )
        print("INFO: client plugin state " + json.dumps(plugin_state, sort_keys=True), flush=True)
        if legacy and not all(plugin_state.values()):
            raise RuntimeError("one or more required legacy client integrations did not load")
        wait_for(lambda: execute("return ![...document.querySelectorAll('.splashscreen,#splashscreen,.docspinner')].some(x=>x.offsetParent!==null) && !![...document.querySelectorAll('.card')].find(x=>x.offsetParent!==null)"), 30, "settled home rendering")
        time.sleep(3)
        screenshot("home")
        if legacy:
            stage = "hover trailer"
            wait_for(lambda: execute("return !![...document.querySelectorAll('.card[data-type=Series],.card[data-itemtype=Series]')].find(x=>x.offsetParent!==null)"), 30, "series card")
            execute("const c=[...document.querySelectorAll('.card[data-type=Series],.card[data-itemtype=Series]')].find(x=>x.offsetParent!==null);c.dispatchEvent(new MouseEvent('mouseenter',{bubbles:false,view:window}));return true")
            wait_for(lambda: execute("return !!document.querySelector('.hovertrailer-progress') || !!document.querySelector('video.ht-local-video,iframe[src*=youtube-nocookie]')"), 5, "hover listener response")
            wait_for(lambda: execute("return !!document.querySelector('video.ht-local-video,iframe[src*=youtube-nocookie]')"), 30, "hover trailer preview")
            execute("document.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',code:'Escape',bubbles:true}));return true")
        stage = "episode navigation"
        request("POST", root + "/url", {"url": base + "/web/#/details?id=" + item_id})
        wait_for(lambda: execute("return document.body.innerText.length>100 && location.hash.includes('details')"), 30, "episode details")
        wait_for(lambda: execute("return !![...document.querySelectorAll('.itemName,.itemName-primary,.detailPagePrimaryContainer')].find(x=>x.offsetParent!==null) && ![...document.querySelectorAll('.splashscreen,#splashscreen,.docspinner')].some(x=>x.offsetParent!==null)"), 30, "settled episode details")
        stage = "playback capability"
        playback = execute_async("const id=arguments[0],done=arguments[arguments.length-1],c=window.ApiClient;c.getPlaybackInfo(id,{}).then(x=>{const s=(x.MediaSources||[]).flatMap(m=>m.MediaStreams||[]),langs=s.filter(v=>v.Type==='Subtitle').map(v=>(v.Language||'').toLowerCase());done({audio:s.some(v=>v.Type==='Audio'),ar:langs.some(v=>v==='ara'||v==='ar'),en:langs.some(v=>v==='eng'||v==='en')})}).catch(e=>done({error:String(e)}))", [item_id])
        if not playback or not playback.get("audio") or not playback.get("ar") or not playback.get("en"):
            raise RuntimeError("expected audio and Arabic/English subtitle streams were not available")
        segments = None
        if legacy:
            segments = execute_async("const id=arguments[0],done=arguments[arguments.length-1],u=window.ApiClient.getUrl('/MediaSegments/'+id);window.ApiClient.ajax({type:'GET',url:u,dataType:'json'}).then(x=>done(x)).catch(e=>done({error:String(e)}))", [item_id])
            intro = next((x for x in (segments or {}).get("Items", []) if x.get("Type") == "Intro"), None)
            if not intro:
                raise RuntimeError("selected episode has no Intro media segment")
        stage = "playback start"
        play = wait_for(lambda: find_any((
            ".itemDetailPage:not(.hide) button.btnPlay",
            ".itemDetailPage:not(.hide) .detailButton.btnPlay",
            ".mainAnimatedPage:not(.hide) button.btnPlay",
            ".mainAnimatedPage:not(.hide) button[data-action='play']",
        )), 20, "play button")
        time.sleep(5)
        screenshot("details")
        if capture_only:
            stage = "capture-only logout"
            execute_async("const done=arguments[arguments.length-1];window.ApiClient.logout().then(()=>done(true)).catch(()=>done(false))")
            wait_for(lambda: execute("return !!window.ApiClient && !window.ApiClient.accessToken()"), 30, "capture-only logout")
            print("PASS: Safari home and details screenshots captured")
            return
        click(play)
        try:
            wait_for(lambda: execute("return !!document.querySelector('video')"), 40, "video element")
        except RuntimeError:
            execute("arguments[0].click();return true", [{ELEMENT: play}])
            try:
                wait_for(lambda: execute("return !!document.querySelector('video')"), 40, "video element after retry")
            except RuntimeError as error:
                diagnostic = execute("return {hash:location.hash,visibleButtons:[...document.querySelectorAll('button.btnPlay,.detailButton.btnPlay,button[data-action=play]')].filter(x=>x.offsetParent!==null).map(x=>({cls:x.className,insideDetails:!!x.closest('.itemDetailPage'),insideHero:!!x.closest('#slides-container,.spotlight-section')})).slice(0,8),videos:document.querySelectorAll('video').length}")
                raise RuntimeError(f"{error}; safe state={diagnostic}")
        execute("document.querySelectorAll('video').forEach(v=>v.pause());return true")
        if legacy:
            stage = "intro skip control"
            intro = next(x for x in segments["Items"] if x.get("Type") == "Intro")
            midpoint = (intro["StartTicks"] + min(intro["EndTicks"], intro["StartTicks"] + 30000000)) / 10000000
            execute("const v=document.querySelector('video.htmlvideoplayer,video');v.currentTime=arguments[0];v.dispatchEvent(new Event('timeupdate'));return true", [midpoint])
            wait_for(lambda: execute("const b=document.querySelector('.skip-button');return !!b&&!b.classList.contains('hide')&&!b.classList.contains('skip-button-hidden')"), 20, "intro skip button")
            screenshot("player")
            stage = "in-player episode preview"
            preview_button = wait_for(lambda: find_any(("#popupPreviewButton",)), 30, "episode preview button")
            click(preview_button)
            wait_for(lambda: execute("return !!document.querySelector('#previewPopup .previewListItem,#previewPopup .previewItemContainer')"), 30, "episode preview popup")
            screenshot("player-preview")
            execute("document.querySelector('#previewPopup')?.remove();return true")
        stage = "mobile home navigation"
        request("POST", root + "/url", {"url": base + "/web/#/home"})
        wait_for(lambda: execute("return location.hash.includes('home') && document.querySelectorAll('.homeSectionsContainer,.verticalSection,.itemsContainer').length>0"), 30, "home before mobile layout")
        stage = "mobile viewport"
        request("POST", root + "/window/rect", {"width": 390, "height": 844, "x": 0, "y": 0})
        time.sleep(1)
        layout = execute("const pages=[...document.querySelectorAll('.mainAnimatedPage')].filter(x=>getComputedStyle(x).display!=='none'&&x.getBoundingClientRect().height>0),r=pages.length?pages[pages.length-1].getBoundingClientRect():null;return {innerWidth,media:matchMedia('(max-width:500px)').matches,pageWidth:r&&r.width,pageLeft:r&&r.left,pageRight:r&&r.right,bodyOverflow:getComputedStyle(document.body).overflowX}")
        if layout["innerWidth"] > 500 or not layout["media"]:
            raise RuntimeError(f"Safari WebDriver did not enter mobile width; safe metrics={layout}")
        if not layout["pageWidth"] or layout["pageWidth"] > layout["innerWidth"] + 2 or layout["pageLeft"] < -2 or layout["pageRight"] > layout["innerWidth"] + 2:
            raise RuntimeError(f"active mobile page exceeds the viewport; safe metrics={layout}")
        stage = "logout"
        logout_result = execute_async("const done=arguments[arguments.length-1];window.ApiClient.logout().then(()=>done(true)).catch(()=>done(false))")
        wait_for(lambda: execute("return !!window.ApiClient && !window.ApiClient.accessToken()"), 30, "logout token revocation")
        if not logout_result:
            raise RuntimeError("Jellyfin logout rejected")
        if not find_any(("#txtManualName", "input[autocomplete='username']")):
            request("POST", root + "/url", {"url": base + "/web/"})
        wait_for(lambda: find_any(("#txtManualName", "input[autocomplete='username']")), 30, "logout login page")
        time.sleep(1)
        stage = "relogin"
        login()
        errors = execute("return window.__veinfinErrors||[]") or []
        plugin_errors = [error for error in errors if any(name in json.dumps(error).lower() for name in ("jellyfinenhanced", "intro-skipper", "introskipper", "anilist", "hovertrailer", "inplayer", "kefintweaks", "media-bar", "homescreen"))]
        if plugin_errors:
            raise RuntimeError("installed-plugin client error event occurred during smoke test")
        stage = "final logout"
        logout_result = execute_async("const done=arguments[arguments.length-1];window.ApiClient.logout().then(()=>done(true)).catch(()=>done(false))")
        try:
            wait_for(lambda: execute("return !!window.ApiClient && !window.ApiClient.accessToken()"), 30, "final logout")
        except RuntimeError as error:
            diagnostic = execute("return {hash:location.hash,token:!!(window.ApiClient&&window.ApiClient.accessToken())}")
            raise RuntimeError(f"{error}; result={logout_result}; safe state={diagnostic}")
        print("PASS: public Safari login, dark home, details, playback, bilingual subtitles, mobile layout, and logout/login")
    except Exception as error:
        raise RuntimeError(f"{stage}: {error}") from error
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

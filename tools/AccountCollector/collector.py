"""P01 local collector. Adapted request flow: legacy getFromBlaLink.py and MIT nikke-calc.

Authentication stays in a Windows DPAPI-encrypted session file; stdout is a JSONL protocol.
No imports from the original crawler (_secrets / fixed output paths / side effects).
"""
from __future__ import annotations
import argparse
import asyncio
import ctypes
from ctypes import wintypes
import datetime as dt
import json
import os
from pathlib import Path
import sys
from urllib.parse import urlencode, urlsplit

VERSION = "p01.1"
API = "https://api.blablalink.com/api/game/proxy/"
AREAS = [(83, "한국"), (81, "일본"), (84, "글로벌"), (82, "북미"), (85, "동남아")]
COMMON = {"game_id": "29080", "area_id": "global", "source": "pc_web", "intl_game_id": "29080", "language": "ko", "env": "prod"}
HEADERS = {"Content-Type": "application/json", "Origin": "https://www.blablalink.com", "Referer": "https://www.blablalink.com/",
           "X-Channel-Type": "2", "X-Language": "ko", "X-Common-Params": json.dumps(COMMON)}

def now():
    return dt.datetime.now(dt.timezone.utc).isoformat()

def emit(kind, **fields):
    print(json.dumps({"schemaVersion": 1, "type": kind, **fields}, ensure_ascii=False), flush=True)

def write_json(path, value):
    target = Path(path)
    target.parent.mkdir(parents=True, exist_ok=True)
    temp = target.with_suffix(target.suffix + ".tmp")
    temp.write_text(json.dumps(value, ensure_ascii=False), encoding="utf-8")
    temp.replace(target)

class CollectorError(Exception):
    def __init__(self, code, message):
        super().__init__(message)
        self.code = code

def runtime_failure(exc):
    # Match known signatures only. Never expose raw Playwright text: it may contain
    # request URLs, headers or authentication metadata.
    text = str(exc)
    if 'ERR_NETWORK_ACCESS_DENIED' in text:
        return CollectorError('network_access_denied',
            '수집기의 네트워크 접근이 차단되었습니다. 백엔드 실행 권한이나 방화벽 설정을 확인한 뒤 다시 로그인하세요.')
    if "Executable doesn't exist" in text:
        return CollectorError('browser_missing',
            '로그인용 브라우저를 찾지 못했습니다. Microsoft Edge 설치 상태를 확인하세요.')
    if any(code in text for code in ('ERR_NAME_NOT_RESOLVED', 'ERR_CONNECTION_', 'ERR_INTERNET_DISCONNECTED')):
        return CollectorError('network', '블라블라 로그인 페이지에 연결하지 못했습니다. 네트워크 연결을 확인한 뒤 다시 시도하세요.')
    return CollectorError('collector_failure', '수집기를 실행하지 못했습니다. 연결 상태와 브라우저 설치를 확인하세요.')

class Blob(ctypes.Structure):
    _fields_ = [("cbData", wintypes.DWORD), ("pbData", ctypes.POINTER(ctypes.c_ubyte))]

def protect(data: bytes, decrypt=False) -> bytes:
    if os.name != "nt":
        raise CollectorError("unsupported_platform", "현재 세션 저장은 Windows에서 지원합니다.")
    buffer = ctypes.create_string_buffer(data)
    source = Blob(len(data), ctypes.cast(buffer, ctypes.POINTER(ctypes.c_ubyte)))
    result = Blob()
    crypt = ctypes.windll.crypt32
    fn = crypt.CryptUnprotectData if decrypt else crypt.CryptProtectData
    if not fn(ctypes.byref(source), None, None, None, None, 1, ctypes.byref(result)):
        raise CollectorError("reauth_required", "저장된 세션을 읽을 수 없습니다. 다시 로그인하세요.")
    try:
        return ctypes.string_at(result.pbData, result.cbData)
    finally:
        ctypes.windll.kernel32.LocalFree(result.pbData)

def save_session(path, value):
    target = Path(path)
    target.parent.mkdir(parents=True, exist_ok=True)
    temp = target.with_suffix(".tmp")
    temp.write_bytes(protect(json.dumps(value).encode("utf-8")))
    temp.replace(target)

def load_session(path):
    try:
        return json.loads(protect(Path(path).read_bytes(), decrypt=True))
    except CollectorError:
        raise
    except Exception:
        raise CollectorError("reauth_required", "로그인 세션이 없습니다. 계정을 연결하세요.") from None

async def post(client, route, body, responses=None):
    for attempt in range(3):
        try:
            response = await client.post(API + route, data=json.dumps(body), timeout=30000)
        except Exception:
            if attempt == 2:
                raise CollectorError("network", "블라블라링크 연결 시간이 초과되었습니다.") from None
            await asyncio.sleep(1 + attempt)
            continue
        if response.status == 429 or response.status >= 500:
            if attempt == 2:
                raise CollectorError("upstream", "서버가 일시적으로 응답하지 않습니다. 잠시 후 다시 시도하세요.")
            retry = response.headers.get("retry-after", "")
            delay = float(retry) if retry.replace(".", "", 1).isdigit() else 1 + attempt
            if delay > 60:
                raise CollectorError("rate_limited", "서버가 긴 대기 시간을 요청했습니다. 나중에 다시 시도하세요.")
            await asyncio.sleep(max(0, delay))
            continue
        if response.status in (401, 403):
            raise CollectorError("reauth_required", "로그인 세션 또는 조회 권한을 확인하세요.")
        if not response.ok:
            raise CollectorError("upstream", f"계정 조회 요청이 실패했습니다 (HTTP {response.status}).")
        try:
            payload = await response.json()
        except Exception:
            raise CollectorError("schema", "서버 응답을 JSON으로 읽을 수 없습니다.") from None
        if not isinstance(payload, dict):
            raise CollectorError("schema", "서버 응답 형식이 변경되었습니다.")
        if payload.get("code") == 300001:
            raise CollectorError("reauth_required", "로그인 세션이 만료되었습니다. 다시 로그인하세요.")
        if responses is not None:
            # Save only requested game data endpoints, never login/auth response packets or headers.
            responses.append({"route": route, "observedAt": now(), "response": payload})
        return payload
    raise CollectorError("upstream", "요청 실패")

def checked(payload, field=None):
    if payload.get("code") != 0:
        code = "private" if payload.get("code") in (1301002, 1303002) else "upstream"
        raise CollectorError(code, "스펙 공개 설정 또는 계정 조회 권한을 확인하세요." if code == "private" else "계정 상세 요청이 실패했습니다.")
    data = payload.get("data")
    if not isinstance(data, dict) or (field and not isinstance(data.get(field), list)):
        raise CollectorError("schema", "필수 계정 데이터 필드가 없습니다.")
    return data

def profile_nickname(payload, area):
    info=(payload.get('data') or {}).get('basic_info') if payload.get('code')==0 else None
    if not isinstance(info,dict) or str(info.get('area_id'))!=str(area):return None
    name=info.get('nickname')
    return name.strip() if isinstance(name,str) and name.strip() else None

def profile_icon_id(payload,area):
    info=(payload.get('data') or {}).get('basic_info') if payload.get('code')==0 else None
    if not isinstance(info,dict) or str(info.get('area_id'))!=str(area):return None
    value=info.get('icon_id')
    return value if type(value) is int and value>=0 else None

async def login(args):
    from playwright.async_api import async_playwright
    async with async_playwright() as p:
        try:
            browser = await p.chromium.launch(channel="msedge", headless=False)
        except Exception:
            browser = await p.chromium.launch(headless=False)
        context = await create_login_context(browser)
        page = await context.new_page()
        captured_headers = {}
        async def observe(request):
            if urlsplit(request.url).hostname == "api.blablalink.com" and request.url.split("?")[0].endswith("/GetUserCharacters"):
                captured_headers.update({k: v for k, v in (await request.all_headers()).items()
                                         if k.lower() not in ("cookie", "host", "content-length", "accept-encoding") and not k.startswith(":")})
        context.on("request", observe)
        target = "https://www.blablalink.com/shiftyspad/nikke-list"
        await page.goto("https://www.blablalink.com/login?" + urlencode({"to": target, "back_to": target}), wait_until="domcontentloaded")
        emit("progress", stage="awaiting_login", message="열린 브라우저에서 로그인하세요.")
        try:
            for _ in range(600):
                if page.is_closed():
                    raise CollectorError("login_closed", "로그인 창이 닫혔습니다. 다시 연결하세요.")
                cookies = {c["name"]: c["value"] for c in await context.cookies("https://api.blablalink.com")}
                openid = cookies.get("game_openid")
                if cookies.get("game_token") and openid:
                    headers = {**HEADERS, **captured_headers}
                    client = await p.request.new_context(storage_state=await context.storage_state(), extra_http_headers=headers)
                    choices = []
                    try:
                        for area, label in AREAS:
                            payload = await post(client, "Game/GetUserCharacters", {"intl_open_id": openid, "nikke_area_id": area})
                            chars = (payload.get("data") or {}).get("characters") if payload.get("code") == 0 else None
                            if isinstance(chars, list) and chars:
                                choices.append({"area": area, "label": label, "characterCount": len(chars), "openId": openid})
                        if choices:
                            save_session(args.session, {"state": await client.storage_state(), "headers": headers, "openId": openid})
                            write_json(args.result, {"schemaVersion": 1, "choices": choices})
                            emit("complete")
                            return
                        emit("progress", stage="awaiting_login", message="조회 가능한 로스터가 없습니다. 프로필 공개 설정과 게임 계정 연결을 확인하세요.")
                    finally:
                        await client.dispose()
                    await asyncio.sleep(8)
                await asyncio.sleep(1)
            raise CollectorError("login_timeout", "로그인 대기 시간이 끝났습니다. 다시 연결하세요.")
        finally:
            await browser.close()

async def create_login_context(browser):
    # Never put API headers on the interactive browser context. They would leak to
    # login/CDN/telemetry origins and trigger forbidden CORS preflights.
    return await browser.new_context(locale="en-US")

async def collect(args):
    from playwright.async_api import async_playwright
    session = load_session(args.session)
    if session.get("openId") != args.openid:
        raise CollectorError("account_mismatch", "연결된 세션의 계정이 다릅니다. 다시 연결하세요.")
    raw = {"schemaVersion": 1, "source": "blablalink", "collectorVersion": VERSION, "openId": args.openid,
           "area": args.area, "startedAt": now(), "characters": [], "details": [], "stateEffects": [], "responses": []}
    async with async_playwright() as p:
        client = await p.request.new_context(storage_state=session["state"], extra_http_headers=session["headers"])
        body = {"intl_open_id": args.openid, "nikke_area_id": args.area}
        try:
            first = checked(await post(client, "Game/GetUserCharacters", body, raw["responses"]), "characters")
            # The site's avatar_frame statistic is not an equipped game-frame ID.
            # The inspected game profile endpoints do not provide that selection.
            raw['profileFrameId'] = None
            raw['profileFrameStatus'] = 'not_provided_by_source'
            try:
                profile=await post(client,"Game/GetUserProfileBasicInfo",body,raw["responses"])
                raw['nickname']=profile_nickname(profile,args.area)
                raw['profileIconId']=profile_icon_id(profile,args.area)
                if raw['profileIconId']:
                    try:
                        from profile_avatar_assets import prepare
                        raw['avatarPath']=await asyncio.to_thread(prepare,raw['profileIconId'],Path(args.session).parent.parent/'presentation')
                    except Exception:
                        raw['avatarPath']=None  # Artwork availability does not invalidate collected specs.
            except CollectorError as error:
                if error.code in ('reauth_required','account_mismatch'):raise
                # Optional display metadata must not discard an otherwise valid roster.
                raw['nickname']=None
            raw["characters"] = first["characters"]
            codes = [c["name_code"] for c in first["characters"]]
            if not codes:
                raise CollectorError("empty_roster", "로스터가 비어 있습니다.")
            emit("progress", stage="collecting", expected=len(codes), collected=0)
            for start in range(0, len(codes), 10):
                chunk = checked(await post(client, "Game/GetUserCharacterDetails", {**body, "name_codes": codes[start:start + 10]}, raw["responses"]), "character_details")
                raw["details"].extend(chunk["character_details"])
                effects = chunk.get("state_effects", [])
                if not isinstance(effects, list):
                    raise CollectorError("schema", "옵션 사전 형식이 변경되었습니다.")
                raw["stateEffects"].extend(effects)
                emit("progress", stage="collecting", expected=len(codes), collected=len(raw["details"]))
            outpost = await post(client, "Game/GetUserProfileOutpostInfo", body, raw["responses"])
            raw["outpost"] = (outpost.get("data") or {}).get("outpost_info") if outpost.get("code") == 0 else None
            raw["rosterAfter"] = checked(await post(client, "Game/GetUserCharacters", body, raw["responses"]), "characters")["characters"]
            save_session(args.session, {**session, "state": await client.storage_state()})
        finally:
            raw["completedAt"] = now()
            write_json(args.result, raw)
            await client.dispose()
    emit("complete")

def main():
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=["login", "collect"])
    parser.add_argument("--session", required=True)
    parser.add_argument("--result", required=True)
    parser.add_argument("--openid")
    parser.add_argument("--area", type=int)
    args = parser.parse_args()
    try:
        if args.action == "collect" and (not args.openid or args.area not in dict(AREAS)):
            raise CollectorError("invalid_account", "계정·서버를 먼저 선택하세요.")
        asyncio.run(login(args) if args.action == "login" else collect(args))
        return 0
    except CollectorError as exc:
        emit("error", code=exc.code, message=str(exc))
    except ImportError:
        emit("error", code="dependency", message="수집기 의존성을 설치하세요 (npm run setup:sync).")
    except Exception as exc:
        # Do not echo HTTP/Playwright exception strings; they can contain request metadata.
        failure = runtime_failure(exc)
        emit("error", code=failure.code, message=str(failure))
    return 1

if __name__ == "__main__":
    sys.exit(main())

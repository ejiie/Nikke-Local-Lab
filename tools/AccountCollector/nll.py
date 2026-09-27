"""User-invoked Nikke-Simul collector bridge. Never emit auth or response bodies."""
import argparse
import asyncio
import hashlib
import hmac
import json
from pathlib import Path
from types import SimpleNamespace
import secrets
import collector
from presentation_assets import download, normal_resource_uri, atomic, PNG


def legacy(envelope):
    routes = {"GetUserCharacters", "GetUserCharacterDetails", "GetUserProfileOutpostInfo", "GetUserProfileBasicInfo"}
    packets = []
    seen_roster = False
    for packet in envelope["responses"]:
        route = packet["route"].split("/")[-1]
        if route not in routes or packet["response"].get("code") != 0:
            continue
        if route == "GetUserCharacters":
            if seen_roster:
                continue
            seen_roster = True
        packets.append({"endpoint": route, "url": "", "data": packet["response"]["data"]})
    if envelope["characters"] != envelope["rosterAfter"]:
        raise collector.CollectorError("account_changed_during_import", "가져오는 동안 계정 정보가 변경되었습니다. 다시 시도해 주세요.")
    return {"uid": "", "phase_1_initial_load": packets, "phase_2_after_click": []}


def union_metadata(payload, area, key):
    data = collector.checked(payload)
    card = data.get("card")
    if card is None:
        return {"status": "none"}
    if not isinstance(card, dict) or int(card.get("nikke_area_id", 0)) != area:
        raise collector.CollectorError("union_area_mismatch", "블라블라의 연결 서버와 선택 서버를 확인해 주세요.")
    name, level, identity = card.get("guild_name"), card.get("guild_level"), card.get("guild_id")
    if not isinstance(name, str) or not 1 <= len(name.strip()) <= 64 or type(level) is not int or level < 1 or not identity:
        raise collector.CollectorError("union_metadata_invalid", "유니온 정보를 확인하지 못했습니다.")
    fingerprint = hmac.new(key, f"blablalink-union/{area}/{identity}".encode(), hashlib.sha256).hexdigest()
    return {"status": "member", "name": name.strip(), "level": level, "fingerprint": fingerprint, "icon": card.get("guild_icon")}


async def main(args):
    root = Path(args.root)
    root.mkdir(parents=True, exist_ok=True)
    session = root / "session.dpapi"
    if args.action == "connect":
        private = root / "choices.private.json"
        if not session.exists() or not private.exists():
            await collector.login(SimpleNamespace(session=str(session), result=str(private)))
        choices = json.loads(private.read_text(encoding="utf-8"))["choices"]
        collector.write_json(args.result, {"choices": [{"area": c["area"], "label": c["label"], "characterCount": c["characterCount"]} for c in choices]})
        return
    current = collector.load_session(session)
    choices = json.loads((root / "choices.private.json").read_text(encoding="utf-8"))["choices"]
    if args.area not in [c["area"] for c in choices]:
        raise collector.CollectorError("account_area_invalid", "서버를 선택해 주세요.")
    envelope_path = root / "collected.private.json"
    await collector.collect(SimpleNamespace(session=str(session), result=str(envelope_path), openid=current["openId"], area=args.area))
    envelope = json.loads(envelope_path.read_text(encoding="utf-8"))
    from playwright.async_api import async_playwright
    async with async_playwright() as p:
        current = collector.load_session(session)
        client = await p.request.new_context(storage_state=current["state"], extra_http_headers=current["headers"])
        try:
            guild = await collector.post(client, "Game/GetMyGuildInfo", {"nikke_area_id": args.area})
        finally:
            await client.dispose()
    key_path = root.parent / "union-key.dpapi"
    if not key_path.exists(): atomic(key_path, collector.protect(secrets.token_bytes(32)))
    metadata = union_metadata(guild, args.area, collector.protect(key_path.read_bytes(), decrypt=True))
    presentation = root.parent / "presentation"
    portrait = None
    if envelope.get("avatarPath"):
        candidate = presentation / envelope["avatarPath"].removeprefix("/editor/")
        if candidate.is_file(): portrait = str(candidate.resolve())
    if not portrait:
        raise collector.CollectorError("account_portrait_missing", "대표 사진을 준비하지 못했습니다. 다시 시도해 주세요.")
    metadata["portrait"] = portrait
    from profile_frame_assets import prepare as prepare_frame
    metadata["frame"] = prepare_frame(envelope.get("profileFrameId"), root.parent.parent, root)
    metadata["frameStatus"] = envelope.get("profileFrameStatus", "unresolved")
    if metadata["status"] == "member":
        rows = json.loads(download(normal_resource_uri("guild/guild_emblem.json")))
        row = next((r for r in rows if r["id"] == metadata["icon"]), None)
        if row is None: raise collector.CollectorError("union_emblem_missing", "유니온 엠블럼을 찾지 못했습니다.")
        picture = download(normal_resource_uri(f'icon/emblem/ig_{row["resource_id"]}.png'))
        if not picture.startswith(PNG): raise ValueError("invalid image")
        emblem = root / "emblem.png"
        atomic(emblem, picture)
        metadata["emblem"] = str(emblem.resolve())
    metadata.pop("icon", None)
    collector.write_json(args.raw, legacy(envelope))
    collector.write_json(args.result, metadata)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=["connect", "collect"])
    parser.add_argument("--root", required=True)
    parser.add_argument("--result", required=True)
    parser.add_argument("--raw")
    parser.add_argument("--area", type=int)
    args = parser.parse_args()
    try:
        asyncio.run(main(args))
    except collector.CollectorError as error:
        if error.code == "reauth_required":
            (Path(args.root) / "session.dpapi").unlink(missing_ok=True)
        print(error.code)
        raise SystemExit(1)
    except Exception:
        print("account_collection_failed")
        raise SystemExit(1)

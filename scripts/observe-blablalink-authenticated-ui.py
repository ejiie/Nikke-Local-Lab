import argparse
import asyncio
import json
import re
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import urlsplit, urlunsplit

from playwright.async_api import async_playwright


BASE_URL = "https://www.blablalink.com"
API_HOST = "api.blablalink.com"
STATIC_HOST = "sg-tools-cdn.blablalink.com"


def load_env(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for raw_line in path.read_text(encoding="utf-8-sig").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        values[key] = value
    return values


def sanitized_url(value: str) -> str:
    parts = urlsplit(value)
    return urlunsplit((parts.scheme, parts.netloc, parts.path, "", ""))


async def click_first(page, patterns: list[str]) -> str | None:
    for pattern in patterns:
        candidates = [
            page.get_by_role("button", name=re.compile(pattern, re.I)),
            page.get_by_role("tab", name=re.compile(pattern, re.I)),
            page.get_by_text(re.compile(pattern, re.I), exact=True),
        ]
        for candidate in candidates:
            try:
                if await candidate.count() > 0:
                    await candidate.first.click(timeout=5000)
                    return pattern
            except Exception:
                continue
    return None


async def dismiss_cookie_banner(page) -> None:
    await click_first(page, [
        r"reject all optional",
        r"accept all optional",
        r"선택 쿠키 모두 거부",
        r"선택 쿠키 모두 허용",
    ])


async def login(page, login_id: str, password: str, region: str,
                login_seen: asyncio.Event) -> None:
    await page.goto(f"{BASE_URL}/login", wait_until="domcontentloaded")
    await dismiss_cookie_banner(page)

    region_option = page.get_by_text(region, exact=False)
    try:
        await region_option.last.click(timeout=12000)
    except Exception:
        await click_first(page, [r"select region", r"지역 선택"])
        await region_option.last.click(timeout=8000)

    email = page.get_by_placeholder(re.compile(r"email|이메일", re.I))
    if await email.count() == 0:
        email = page.locator('input[type="email"], input[type="text"]')
    await email.first.fill(login_id, timeout=12000)
    await page.locator('input[type="password"]').first.fill(password, timeout=12000)
    clicked = await click_first(page, [r"^log\s*in$", r"^로그인$"])
    if clicked is None:
        raise RuntimeError("blablalink_login_button_missing")
    try:
        await asyncio.wait_for(login_seen.wait(), timeout=90)
    except asyncio.TimeoutError as exc:
        raise RuntimeError("blablalink_authenticated_checklogin_missing") from exc


async def wait_for_manual_login(page, login_seen: asyncio.Event) -> None:
    await page.goto(f"{BASE_URL}/login", wait_until="domcontentloaded")
    await dismiss_cookie_banner(page)
    try:
        await asyncio.wait_for(login_seen.wait(), timeout=600)
    except asyncio.TimeoutError as exc:
        raise RuntimeError("blablalink_manual_login_timeout") from exc


async def open_character_from_authenticated_list(page, character_name: str) -> str:
    await page.goto(f"{BASE_URL}/shiftyspad/nikke-list", wait_until="networkidle")
    await page.wait_for_timeout(3000)
    candidates = [
        page.get_by_text(character_name, exact=True),
        page.locator("a").filter(has_text=re.compile(rf"^{re.escape(character_name)}$")),
        page.locator("a").filter(has_text=re.compile(re.escape(character_name))),
    ]
    for candidate in candidates:
        try:
            if await candidate.count() == 0:
                continue
            await candidate.first.click(timeout=8000)
            await page.wait_for_url(re.compile(r"/shiftyspad/nikke(?:\?|$)"), timeout=15000)
            await page.wait_for_load_state("networkidle")
            return "list_card_clicked"
        except Exception:
            continue
    return "list_card_not_found"


async def collect_dom_assets(page) -> dict:
    return await page.evaluate(
        """
        () => {
          const clean = (value) => {
            if (!value) return null;
            try { const url = new URL(value, location.href); url.search = ''; url.hash = ''; return url.href; }
            catch { return value; }
          };
          const images = [...document.images].map((image) => ({
            src: clean(image.currentSrc || image.src),
            alt: image.alt || '',
            className: typeof image.className === 'string' ? image.className : '',
            width: image.naturalWidth,
            height: image.naturalHeight
          })).filter((item) => item.src);
          const backgrounds = [...document.querySelectorAll('*')].map((element) => {
            const value = getComputedStyle(element).backgroundImage;
            const match = /url\\([\"']?(.*?)[\"']?\\)/.exec(value || '');
            if (!match) return null;
            return {
              src: clean(match[1]),
              tag: element.tagName.toLowerCase(),
              className: typeof element.className === 'string' ? element.className : ''
            };
          }).filter(Boolean);
          const controls = [...document.querySelectorAll('button,[role="tab"]')].map((element) => ({
            text: (element.textContent || '').trim().replace(/\\s+/g, ' ').slice(0, 80),
            className: typeof element.className === 'string' ? element.className : '',
            ariaSelected: element.getAttribute('aria-selected')
          })).filter((item) => item.text);
          return { images, backgrounds, controls };
        }
        """
    )


async def main_async(args) -> int:
    env = load_env(Path(args.env_path))
    required = [] if args.manual_login else ["NIKKE_BLABLA_ID", "NIKKE_BLABLA_PW"]
    missing = [key for key in required if not env.get(key)]
    if missing:
        raise RuntimeError("blablalink_env_missing:" + ",".join(missing))

    output_root = Path(args.output_root)
    output_root.mkdir(parents=True, exist_ok=True)
    login_seen = asyncio.Event()
    static_responses: dict[str, dict] = {}
    api_endpoints: set[str] = set()

    async with async_playwright() as playwright:
        browser = await playwright.chromium.launch(headless=args.headless)
        context = await browser.new_context(locale="en-US", viewport={"width": 1440, "height": 1100})
        page = await context.new_page()

        async def observe_response(response) -> None:
            parsed = urlsplit(response.url)
            if parsed.hostname == API_HOST:
                endpoint = parsed.path.rstrip("/").split("/")[-1]
                api_endpoints.add(endpoint)
                if "CheckLogin" in endpoint and response.ok:
                    try:
                        payload = await response.json()
                        if payload.get("code") == 0:
                            login_seen.set()
                    except Exception:
                        pass
            if parsed.hostname == STATIC_HOST:
                content_type = response.headers.get("content-type", "")
                if response.request.resource_type == "image" or content_type.startswith("image/"):
                    safe = sanitized_url(response.url)
                    static_responses[safe] = {
                        "url": safe,
                        "contentType": content_type.split(";", 1)[0],
                        "status": response.status,
                    }

        page.on("response", lambda response: asyncio.create_task(observe_response(response)))
        navigation_code = "direct_character_url"
        if args.manual_login:
            await wait_for_manual_login(page, login_seen)
            navigation_code = await open_character_from_authenticated_list(
                page, args.character_name
            )
        else:
            await login(
                page,
                env["NIKKE_BLABLA_ID"],
                env["NIKKE_BLABLA_PW"],
                env.get("NIKKE_REGION", "JP/KR/NA/SEA/Global"),
                login_seen,
            )
            target = f"{BASE_URL}/shiftyspad/nikke?from=list&nikke={args.nikke}"
            await page.goto(target, wait_until="networkidle")
        await page.wait_for_timeout(4000)
        await page.screenshot(path=str(output_root / "detail-default.png"), full_page=True)
        observations: dict[str, dict] = {"default": await collect_dom_assets(page)}

        tab_specs = {
            "equipment": [r"^equipment$", r"^장비$"],
            "skill": [r"^skill$", r"^스킬$"],
            "collection": [r"collection", r"favorite", r"소장품", r"애장품"],
        }
        clicked_tabs: dict[str, bool] = {}
        for code, patterns in tab_specs.items():
            clicked = await click_first(page, patterns)
            clicked_tabs[code] = clicked is not None
            if clicked:
                await page.wait_for_timeout(1800)
            observations[code] = await collect_dom_assets(page)
            await page.screenshot(path=str(output_root / f"detail-{code}.png"), full_page=True)

        report = {
            "schemaVersion": 1,
            "contractId": "nll/blablalink-authenticated-ui-observation/v1",
            "observedAtUtc": datetime.now(timezone.utc).isoformat(),
            "authenticatedCheckLoginObserved": login_seen.is_set(),
            "credentialPersisted": False,
            "cookieOrTokenPersisted": False,
            "requestBodyPersisted": False,
            "currentPage": sanitized_url(page.url),
            "nikkeCode": str(args.nikke),
            "requestedCharacterName": args.character_name,
            "navigationCode": navigation_code,
            "clickedTabs": clicked_tabs,
            "apiEndpointNames": sorted(api_endpoints),
            "staticImageResponses": sorted(static_responses.values(), key=lambda item: item["url"]),
            "dom": observations,
        }
        (output_root / "observation.json").write_text(
            json.dumps(report, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
        if args.hold_seconds > 0:
            await page.wait_for_timeout(args.hold_seconds * 1000)
        await context.close()
        await browser.close()
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--env-path", required=True)
    parser.add_argument("--output-root", required=True)
    parser.add_argument("--nikke", default="90")
    parser.add_argument("--character-name", default="레드 후드")
    parser.add_argument("--headless", action="store_true")
    parser.add_argument("--manual-login", action="store_true")
    parser.add_argument("--hold-seconds", type=int, default=0)
    return asyncio.run(main_async(parser.parse_args()))


if __name__ == "__main__":
    raise SystemExit(main())

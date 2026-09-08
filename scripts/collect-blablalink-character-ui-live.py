import argparse
import asyncio
import json
import re
from pathlib import Path
from urllib.parse import urlsplit, urlunsplit

from playwright.async_api import async_playwright


LIST_URL = "https://www.blablalink.com/shiftyspad/nikke-list"


def clean_url(value: str) -> str:
    if not value or value.startswith("data:"):
        return value
    parts = urlsplit(value)
    return urlunsplit((parts.scheme, parts.netloc, parts.path, "", ""))


async def collect_view(page) -> dict:
    return await page.evaluate(
        r"""
        () => {
          const clean = (value) => {
            if (!value || value.startsWith('data:')) return value || '';
            try { const url = new URL(value, location.href); url.search = ''; url.hash = ''; return url.href; }
            catch { return value; }
          };
          const images = [...document.images].map((image) => ({
            src: clean(image.currentSrc || image.src || image.dataset.src || ''),
            dataSrc: clean(image.dataset.src || ''),
            alt: image.alt || '',
            className: typeof image.className === 'string' ? image.className : '',
            width: image.naturalWidth,
            height: image.naturalHeight,
            parentClass: typeof image.parentElement?.className === 'string'
              ? image.parentElement.className : ''
          })).filter((item) => item.src || item.dataSrc);
          const backgrounds = [...document.querySelectorAll('*')].map((element) => {
            const value = getComputedStyle(element).backgroundImage || '';
            const match = /url\\(["']?(.*?)["']?\\)/.exec(value);
            if (!match) return null;
            return {
              src: clean(match[1]),
              tag: element.tagName.toLowerCase(),
              className: typeof element.className === 'string' ? element.className : ''
            };
          }).filter(Boolean);
          const nav = document.querySelector('[data-cname="nav"]');
          const scope = nav?.parentElement || document.querySelector('main') || document.body;
          const controls = [...scope.querySelectorAll('button,[role="tab"],[data-cname]')]
            .map((element) => ({
              tag: element.tagName.toLowerCase(),
              text: (element.textContent || '').trim().replace(/\\s+/g, ' ')
                .replace(/\\b\\d{7,12}\\b/g, '[redacted-number]').slice(0, 180),
              className: typeof element.className === 'string' ? element.className : '',
              dataCname: element.getAttribute('data-cname') || '',
              ariaSelected: element.getAttribute('aria-selected')
            })).filter((item) => item.text || item.dataCname);
          return { images, backgrounds, controls };
        }
        """
    )


async def click_tab(page, patterns: list[str]) -> bool:
    nav_items = page.locator('[data-cname="nav"] > *')
    for index in range(await nav_items.count()):
        item = nav_items.nth(index)
        text = re.sub(r"\s+", " ", (await item.inner_text()).strip())
        if not any(re.search(pattern, text, re.I) for pattern in patterns):
            continue
        try:
            await item.click(timeout=8000, force=True)
            await page.wait_for_timeout(1800)
            return True
        except Exception:
            pass
    for pattern in patterns:
        regex = re.compile(pattern, re.I)
        candidates = [
            page.get_by_role("tab", name=regex),
            page.get_by_role("button", name=regex),
            page.get_by_text(regex, exact=True),
        ]
        for candidate in candidates:
            try:
                if await candidate.count() == 0:
                    continue
                await candidate.first.click(timeout=8000)
                await page.wait_for_timeout(1800)
                return True
            except Exception:
                continue
    return False


async def main_async(args: argparse.Namespace) -> int:
    output_root = Path(args.output_root)
    output_root.mkdir(parents=True, exist_ok=True)
    requested_images: set[str] = set()

    async with async_playwright() as playwright:
        browser = await playwright.chromium.connect_over_cdp(args.cdp_url)
        if not browser.contexts:
            raise RuntimeError("blablalink_cdp_context_missing")
        context = browser.contexts[0]
        page = next((item for item in context.pages if "blablalink.com" in item.url), None)
        if page is None:
            page = await context.new_page()

        async def observe_response(response) -> None:
            content_type = response.headers.get("content-type", "")
            if response.request.resource_type == "image" or content_type.startswith("image/"):
                requested_images.add(clean_url(response.url))

        page.on("response", lambda response: asyncio.create_task(observe_response(response)))
        await page.bring_to_front()
        if "/shiftyspad/nikke-list" not in page.url:
            await page.goto(LIST_URL, wait_until="networkidle")
            await page.wait_for_timeout(2500)

        cards = page.locator('[data-cname="player-item"]')
        matching_cards: list[tuple[int, object, str]] = []
        for index in range(await cards.count()):
            card = cards.nth(index)
            text = re.sub(r"\s+", " ", (await card.inner_text()).strip())
            if args.character_name.lower() not in text.lower():
                continue
            if text.lower().endswith(args.character_name.lower()):
                matching_cards.append((len(text), card, text))
        if not matching_cards:
            raise RuntimeError("blablalink_character_card_missing:" + args.character_name)
        _, selected, selected_text = min(matching_cards, key=lambda item: item[0])

        card_structure = await selected.evaluate(
            r"""
            (card) => ({
              text: (card.textContent || '').trim().replace(/\s+/g, ' '),
              className: card.className || '',
              images: [...card.querySelectorAll('img')].map((image) => ({
                src: image.currentSrc || image.src || image.dataset.src || '',
                className: image.className || '',
                alt: image.alt || '',
                width: image.naturalWidth,
                height: image.naturalHeight,
                parentClass: image.parentElement?.className || ''
              })),
              nodes: [...card.querySelectorAll('[class]')].map((element) => ({
                tag: element.tagName.toLowerCase(),
                className: element.className || '',
                text: [...element.childNodes]
                  .filter((node) => node.nodeType === Node.TEXT_NODE)
                  .map((node) => node.textContent || '').join(' ').trim(),
                backgroundImage: getComputedStyle(element).backgroundImage || '',
                maskImage: getComputedStyle(element).maskImage || '',
                before: {
                  content: getComputedStyle(element, '::before').content || '',
                  backgroundImage: getComputedStyle(element, '::before').backgroundImage || '',
                  maskImage: getComputedStyle(element, '::before').maskImage || ''
                },
                after: {
                  content: getComputedStyle(element, '::after').content || '',
                  backgroundImage: getComputedStyle(element, '::after').backgroundImage || '',
                  maskImage: getComputedStyle(element, '::after').maskImage || ''
                }
              })).filter((item) => item.text || item.backgroundImage !== 'none' ||
                item.maskImage !== 'none' || item.before.content !== 'none' ||
                item.before.backgroundImage !== 'none' || item.after.content !== 'none' ||
                item.after.backgroundImage !== 'none' ||
                /level|star|core|job|burst|weapon|code|name|rarity/i.test(item.className))
            })
            """
        )
        await page.screenshot(path=str(output_root / "list-before-detail.png"), full_page=True)
        await selected.click(timeout=10000)
        await page.wait_for_url(re.compile(r"/shiftyspad/nikke(?:\?|$)"), timeout=15000)
        await page.wait_for_load_state("networkidle")
        await page.wait_for_timeout(2500)
        await page.evaluate("window.scrollTo(0, 0)")
        await page.wait_for_timeout(500)
        await page.screenshot(path=str(output_root / "detail-top.png"), full_page=False)

        nav_structure = await page.locator('[data-cname="nav"]').first.evaluate(
            r"""
            (nav) => ({
              className: nav.className || '',
              html: nav.outerHTML,
              items: [...nav.children].map((item, index) => ({
                index,
                tag: item.tagName.toLowerCase(),
                text: (item.textContent || '').trim().replace(/\s+/g, ' '),
                className: item.className || ''
              }))
            })
            """
        )
        detail_top_structure = await page.evaluate(
            r"""
            () => {
              const nav = document.querySelector('[data-cname="nav"]');
              const root = nav?.parentElement?.previousElementSibling || nav?.parentElement;
              if (!root) return null;
              return {
                text: (root.textContent || '').trim().replace(/\s+/g, ' ').slice(0, 1200),
                html: root.outerHTML.slice(0, 30000),
                images: [...root.querySelectorAll('img')].map((image) => ({
                  src: image.currentSrc || image.src || '',
                  className: image.className || '',
                  width: image.naturalWidth,
                  height: image.naturalHeight,
                  parentClass: image.parentElement?.className || ''
                }))
              };
            }
            """
        )

        views: dict[str, dict] = {}
        screenshots = {
            "default": "detail-default.png",
            "equipment": "detail-equipment.png",
            "skill": "detail-skill.png",
            "collection": "detail-collection.png",
        }
        views["default"] = await collect_view(page)
        await page.screenshot(path=str(output_root / screenshots["default"]), full_page=True)

        tab_specs = {
            "equipment": [r"^equipment$", r"^장비$"],
            "skill": [r"^skill$", r"^스킬$"],
            "collection": [r"^collection$", r"^favorite item$", r"^소장품$", r"^애장품$"],
        }
        clicked_tabs: dict[str, bool] = {}
        for code, patterns in tab_specs.items():
            clicked_tabs[code] = await click_tab(page, patterns)
            views[code] = await collect_view(page)
            await page.screenshot(path=str(output_root / screenshots[code]), full_page=True)

        report = {
            "schemaVersion": 1,
            "contractId": "nll/blablalink-live-character-ui-observation/v1",
            "currentPage": clean_url(page.url),
            "characterName": args.character_name,
            "selectedCardText": selected_text,
            "cardStructure": card_structure,
            "navStructure": nav_structure,
            "detailTopStructure": detail_top_structure,
            "clickedTabs": clicked_tabs,
            "requestedImageUrls": sorted(requested_images),
            "resourcePaths": await page.evaluate("""() => [...new Set(
              performance.getEntriesByType('resource').map(entry => {
                try {
                  const url = new URL(entry.name);
                  return `${url.origin}${url.pathname}`;
                } catch { return ''; }
              }).filter(Boolean))].sort()"""),
            "views": views,
            "credentialPersisted": False,
            "cookieOrTokenPersisted": False,
            "requestBodyPersisted": False,
        }
        (output_root / "character-ui.json").write_text(
            json.dumps(report, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
        print(json.dumps({
            "currentPage": report["currentPage"],
            "selectedCardText": selected_text,
            "clickedTabs": clicked_tabs,
            "requestedImageCount": len(requested_images),
            "viewImageCounts": {
                key: len(value["images"]) for key, value in views.items()
            },
        }, ensure_ascii=False, indent=2))
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--cdp-url", default="http://127.0.0.1:9230")
    parser.add_argument("--output-root", required=True)
    parser.add_argument("--character-name", default="Red Hood")
    return asyncio.run(main_async(parser.parse_args()))


if __name__ == "__main__":
    raise SystemExit(main())

import argparse
import asyncio
import json
import re
from datetime import datetime, timezone
from pathlib import Path

from playwright.async_api import async_playwright


LIST_URL = "https://www.blablalink.com/shiftyspad/nikke-list"


async def main_async(args: argparse.Namespace) -> int:
    output_root = Path(args.output_root)
    output_root.mkdir(parents=True, exist_ok=True)
    async with async_playwright() as playwright:
        browser = await playwright.chromium.connect_over_cdp(args.cdp_url)
        context = browser.contexts[0]
        page = next((item for item in context.pages if "blablalink.com" in item.url), None)
        if page is None:
            raise RuntimeError("blablalink_authenticated_page_missing")
        await page.bring_to_front()
        await page.goto(LIST_URL, wait_until="networkidle")
        await page.wait_for_timeout(2500)
        await page.screenshot(path=str(output_root / "list.png"), full_page=True)
        list_styles = await page.evaluate(
            """
            () => {
              const card = document.querySelector('[data-cname="player-item"]');
              if (!card) return null;
              const rect = (element) => {
                const value = element.getBoundingClientRect();
                return { x: value.x, y: value.y, width: value.width, height: value.height };
              };
              return {
                card: { className: card.className, rect: rect(card) },
                images: [...card.querySelectorAll('img')].map((image) => ({
                  className: image.className || '',
                  srcPath: new URL(image.currentSrc || image.src).pathname,
                  naturalWidth: image.naturalWidth,
                  naturalHeight: image.naturalHeight,
                  rect: rect(image),
                  objectFit: getComputedStyle(image).objectFit,
                  objectPosition: getComputedStyle(image).objectPosition
                })),
                filterImages: [...document.querySelectorAll('button img')]
                  .filter((image) => image.getBoundingClientRect().width > 0)
                  .map((image) => ({
                    alt: image.alt || '',
                    className: image.className || '',
                    srcPath: new URL(image.currentSrc || image.src).pathname,
                    naturalWidth: image.naturalWidth,
                    naturalHeight: image.naturalHeight,
                    rect: rect(image),
                    filter: getComputedStyle(image).filter
                  }))
              };
            }
            """
        )

        card = page.locator(
            '[data-cname="player-item"]',
            has_text=re.compile(args.character_name, re.I),
        ).first
        if await card.count() == 0:
            raise RuntimeError("blablalink_target_character_card_missing")
        await card.click(timeout=10000)
        await page.wait_for_url(re.compile(r"/shiftyspad/nikke(?:\?|$)"), timeout=15000)
        await page.wait_for_load_state("networkidle")
        await page.wait_for_timeout(10000)
        equipment = page.get_by_text(re.compile(r"^(장비|Equipment)$", re.I), exact=True)
        if await equipment.count() > 0:
            await equipment.first.click(timeout=8000)
            await page.wait_for_timeout(1800)
        await page.screenshot(path=str(output_root / "equipment.png"), full_page=True)
        value_styles = await page.evaluate(
            """
            () => {
              const visible = (element) => {
                const rect = element.getBoundingClientRect();
                const style = getComputedStyle(element);
                return rect.width > 0 && rect.height > 0 && style.visibility !== 'hidden';
              };
              const styleOf = (element) => {
                if (!element) return null;
                const style = getComputedStyle(element);
                return {
                  tag: element.tagName.toLowerCase(),
                  className: typeof element.className === 'string' ? element.className : '',
                  color: style.color,
                  backgroundColor: style.backgroundColor,
                  backgroundImage: style.backgroundImage,
                  borderColor: style.borderColor,
                  fontWeight: style.fontWeight
                };
              };
              return [...document.querySelectorAll('body *')]
                .filter((element) => element.children.length === 0 && visible(element))
                .map((element) => ({ element, text: (element.textContent || '').trim() }))
                .filter((item) => /^\\d+(?:\\.\\d+)?%$/.test(item.text))
                .map((item) => ({
                  text: item.text,
                  self: styleOf(item.element),
                  parent: styleOf(item.element.parentElement),
                  grandparent: styleOf(item.element.parentElement?.parentElement),
                  greatGrandparent: styleOf(item.element.parentElement?.parentElement?.parentElement)
                }));
            }
            """
        )
        result = {
            "schemaVersion": 1,
            "observedAtUtc": datetime.now(timezone.utc).isoformat(),
            "authenticatedPageObserved": "/shiftyspad/" in page.url,
            "credentialPersisted": False,
            "cookieOrTokenPersisted": False,
            "listStyles": list_styles,
            "percentageStyles": value_styles,
        }
        (output_root / "style-observation.json").write_text(
            json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
        )
        print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--cdp-url", default="http://127.0.0.1:9230")
    parser.add_argument("--output-root", required=True)
    parser.add_argument("--character-name", default=r"Rapi\s*:\s*Red Hood|Red Hood|레드 후드")
    return asyncio.run(main_async(parser.parse_args()))


if __name__ == "__main__":
    raise SystemExit(main())

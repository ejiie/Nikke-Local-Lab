import argparse
import asyncio
import json
from pathlib import Path

from playwright.async_api import async_playwright


LIST_URL = "https://www.blablalink.com/shiftyspad/nikke-list"


async def main_async(args: argparse.Namespace) -> int:
    output_root = Path(args.output_root)
    output_root.mkdir(parents=True, exist_ok=True)

    async with async_playwright() as playwright:
        browser = await playwright.chromium.connect_over_cdp(args.cdp_url)
        contexts = browser.contexts
        if not contexts:
            raise RuntimeError("blablalink_cdp_context_missing")
        pages = contexts[0].pages
        page = next((item for item in pages if "blablalink.com" in item.url), None)
        if page is None:
            page = await contexts[0].new_page()

        await page.bring_to_front()
        await page.goto(LIST_URL, wait_until="networkidle")
        await page.wait_for_timeout(3000)
        await page.screenshot(path=str(output_root / "nikke-list.png"), full_page=True)

        cards = await page.evaluate(
            """
            () => [...document.querySelectorAll('img.nikkes-player-item-img')]
              .slice(0, 30)
              .map((image, index) => {
                const clickable = image.closest('a,button,[role="button"],[class*="cursor-pointer"]')
                  || image.parentElement;
                const anchor = image.closest('a') || clickable?.closest?.('a');
                return {
                  index,
                  imageSrc: image.currentSrc || image.src,
                  imageClass: image.className || '',
                  clickableTag: clickable?.tagName?.toLowerCase() || '',
                  clickableClass: typeof clickable?.className === 'string' ? clickable.className : '',
                  href: anchor?.href || '',
                  text: (clickable?.textContent || '').trim().replace(/\s+/g, ' ').slice(0, 160),
                  html: (clickable?.outerHTML || '').slice(0, 1200)
                };
              })
            """
        )
        visual_assets = await page.evaluate(
            """
            () => {
              const rows = [...document.querySelectorAll('[data-cname="player-item"]')];
              const evolve = rows.map((card) => {
                const element = card.querySelector('.evolve');
                if (!element) return null;
                return {
                  cardText: (card.textContent || '').trim().replace(/\s+/g, ' '),
                  className: element.className || '',
                  backgroundImage: getComputedStyle(element).backgroundImage || '',
                  text: (element.textContent || '').trim()
                };
              }).filter(Boolean);
              const starImages = rows.flatMap((card) => [...card.querySelectorAll('.nikke-star img')]
                .map((image) => ({
                  cardText: (card.textContent || '').trim().replace(/\s+/g, ' '),
                  src: image.currentSrc || image.src || '',
                  className: image.className || ''
                })));
              return { evolve, starImages };
            }
            """
        )

        result = {
            "url": page.url,
            "title": await page.title(),
            "cardCount": await page.locator("img.nikkes-player-item-img").count(),
            "cards": cards,
            "visualAssets": visual_assets,
        }
        (output_root / "list-probe.json").write_text(
            json.dumps(result, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
        print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--cdp-url", default="http://127.0.0.1:9230")
    parser.add_argument("--output-root", required=True)
    return asyncio.run(main_async(parser.parse_args()))


if __name__ == "__main__":
    raise SystemExit(main())

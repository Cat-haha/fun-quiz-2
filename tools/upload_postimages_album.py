"""
Upload all .avif files under a folder to postimages.org and try to get a single gallery/album link.
Usage (from repo root):
  pip install -U playwright
  python -m playwright install chromium
  python tools/upload_postimages_album.py --dir assets/images/all --album "My Quiz Gallery" --headful --open

Notes:
- Uses Playwright to drive the web UI (more reliable than undocumented HTTP APIs).
- Tries to upload all files in one form submission (Postimages usually creates one album).
- If site limits the single-upload size/count, the script uploads in batches and prints all resulting album/image links.
- If --open is given and $BROWSER is set, the first album link will be opened in the host browser.
"""
import argparse
import asyncio
import os
from pathlib import Path
from playwright.async_api import async_playwright, TimeoutError as PWTimeoutError

FILE_INPUT_SELECTORS = [
    'input[type="file"]',
    'input[name="upload[]"]',
    'input#uploadFiles',
    'input[name="files[]"]'
]
ALBUM_INPUT_SELECTORS = [
    'input[name="album_title"]',
    'input#album-title',
    'input[placeholder*="Album"]',
    'input[placeholder*="album"]'
]
UPLOAD_BUTTON_SELECTORS = [
    'button:has-text("Upload")',
    'button:has-text("Start upload")',
    'button[type="submit"]',
]

async def find_file_input(page):
    for sel in FILE_INPUT_SELECTORS:
        try:
            el = await page.query_selector(sel)
            if el:
                return el, sel
        except Exception:
            pass
    return None, None

async def click_upload(page):
    for sel in UPLOAD_BUTTON_SELECTORS:
        try:
            btn = await page.query_selector(sel)
            if btn:
                await btn.click()
                return True
        except Exception:
            pass
    try:
        await page.keyboard.press("Enter")
        return True
    except Exception:
        return False

async def collect_result_links(page, timeout_ms=120000):
    # Poll for links that look like album/image results
    elapsed = 0
    step = 2000
    found = set()
    while elapsed < timeout_ms:
        # candidate selectors for result links
        anchors = await page.query_selector_all('a[href*="postimages.org"], a[href*="postimg.cc"], div.result a, div.links a, div#links a')
        for a in anchors:
            try:
                href = await a.get_attribute("href")
                if href and ("postimages.org" in href or "postimg.cc" in href):
                    found.add(href)
            except Exception:
                pass
        # also look for album anchors specifically
        album = await page.query_selector('a[href*="/album/"], a[href*="/a/"]')
        if album:
            href = await album.get_attribute("href")
            if href:
                found.add(href)
                # album link is best; return list with album first
                return list(found)
        if found:
            # if we have at least one link, keep polling a bit to gather more
            # return after short stabilization
            await page.wait_for_timeout(2000)
            return list(found)
        await page.wait_for_timeout(step)
        elapsed += step
    return list(found)

async def upload_files(avif_files, album_title=None, headful=False):
    async with async_playwright() as p:
        browser = await p.chromium.launch(headless=not headful)
        page = await browser.new_page()
        await page.goto("https://postimages.org/", wait_until="domcontentloaded")

        file_input, used_sel = await find_file_input(page)
        if not file_input:
            print("ERROR: file input not found on postimages.org. Update selectors.")
            await browser.close()
            return []

        # check whether input supports multiple files
        supports_multiple = await file_input.evaluate("el => !!el.multiple")
        if not supports_multiple:
            print("File input does NOT support multiple files. Script will upload files sequentially.")

        results = []

        if supports_multiple:
            print(f"Uploading {len(avif_files)} files in one request via selector {used_sel} ...")
            await file_input.set_input_files(avif_files)
            # try to set album title if a field exists
            if album_title:
                for sel in ALBUM_INPUT_SELECTORS:
                    try:
                        el = await page.query_selector(sel)
                        if el:
                            await el.fill(album_title)
                            break
                    except Exception:
                        pass
            clicked = await click_upload(page)
            if not clicked:
                print("Warning: upload button not found/clicked; upload may still proceed automatically.")
            # collect links (wait longer since many files)
            links = await collect_result_links(page, timeout_ms=120000)
            results.extend(links)
        else:
            # Upload sequentially; try to set album title for first upload
            for i, f in enumerate(avif_files, start=1):
                print(f"Uploading {i}/{len(avif_files)}: {f}")
                await file_input.set_input_files(f)
                if album_title and i == 1:
                    for sel in ALBUM_INPUT_SELECTORS:
                        try:
                            el = await page.query_selector(sel)
                            if el:
                                await el.fill(album_title)
                                break
                        except Exception:
                            pass
                await click_upload(page)
                links = await collect_result_links(page, timeout_ms=60000)
                if links:
                    results.extend(links)
                # reset to upload another file: navigate back to main upload page if necessary
                await page.goto("https://postimages.org/", wait_until="domcontentloaded")

        await browser.close()
        # dedupe and return
        deduped = []
        for l in results:
            if l not in deduped:
                deduped.append(l)
        return deduped

def collect_avif_files(base_dir):
    base = Path(base_dir)
    if not base.exists():
        raise SystemExit(f"Directory not found: {base_dir}")
    files = [str(p) for p in base.rglob("*.avif")]
    return sorted(files)

def open_in_host_browser(url):
    # use $BROWSER as instructed in devcontainer
    browser_cmd = os.environ.get("BROWSER")
    if not browser_cmd:
        print("Set $BROWSER to a command like xdg-open to auto-open the link.")
        return
    os.system(f'{browser_cmd} "{url}"')

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", required=True, help="root folder containing section subfolders with .avif files")
    ap.add_argument("--album", help="album/gallery title (optional)")
    ap.add_argument("--headful", action="store_true", help="run visible browser")
    ap.add_argument("--open", action="store_true", help="open resulting link in host browser via $BROWSER")
    ap.add_argument("--batch-size", type=int, default=500, help="max files to attempt in a single upload (ignored if input is not multiple)")
    args = ap.parse_args()

    files = collect_avif_files(args.dir)
    if not files:
        print("No .avif files found under", args.dir)
        return

    print(f"Found {len(files)} .avif files.")
    # try single upload first if under batch-size
    batch = files[:args.batch_size]
    links = asyncio.run(upload_files(batch, album_title=args.album, headful=args.headful))
    if links:
        print("Upload produced the following link(s):")
        for l in links:
            print(" -", l)
        if args.open:
            open_in_host_browser(links[0])
        return

    # fallback to smaller batches
    print("No album link found for single upload; falling back to batch uploads...")
    all_links = []
    for i in range(0, len(files), args.batch_size):
        batch = files[i : i + args.batch_size]
        print(f"Uploading batch {i//args.batch_size + 1} ({len(batch)} files)...")
        links = asyncio.run(upload_files(batch, album_title=(args.album if i==0 else None), headful=args.headful))
        all_links.extend(links)
        if args.open and links:
            open_in_host_browser(links[0])
    if all_links:
        print("Collected links:")
        for l in all_links:
            print(" -", l)
    else:
        print("No links produced. Run with --headful to watch and debug the upload process.")

if __name__ == "__main__":
    main()
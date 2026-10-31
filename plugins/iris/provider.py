"""Iris web_extract provider: fetch pages directly and return readable markdown.

Each URL is fetched with httpx and converted with trafilatura. PDFs become plain
text through pypdf. When a page is script-rendered, blocks plain clients, or
yields too little text, Iris renders it once in headless Chromium and extracts
again. Every request, redirect and browser subresource passes Hermes's private
network and website policy checks first.

Config: ``web.extract_backend: iris``. Search stays with another backend.
"""
from __future__ import annotations

import asyncio
import glob
import importlib.util
import io
import logging
import os
import re
from typing import Any, Optional
from urllib.parse import urlparse

import httpx

from agent.web_search_provider import WebSearchProvider

logger = logging.getLogger(__name__)

USER_AGENT = (
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/146.0.0.0 Safari/537.36"
)
FETCH_TIMEOUT = float(os.environ.get("IRIS_FETCH_TIMEOUT", "20"))
RENDER_TIMEOUT = float(os.environ.get("IRIS_RENDER_TIMEOUT", "30"))
MAX_BYTES = int(os.environ.get("IRIS_MAX_BYTES", str(15 * 1024 * 1024)))
CONCURRENCY = int(os.environ.get("IRIS_CONCURRENCY", "6"))
# Below this many characters of extracted text, a page that looks like a
# script-rendered app shell is retried in the browser.
MIN_TEXT = int(os.environ.get("IRIS_MIN_TEXT", "400"))
# Statuses that often mean "a real browser would get through".
RENDER_STATUSES = {401, 403, 406, 429, 503}

_UNSAFE_URL = "Blocked: URL targets a private or internal network address"
_TEXT_TYPES = ("text/plain", "text/markdown", "text/csv", "application/json",
               "application/xml", "text/xml", "application/rss+xml", "application/atom+xml")


class _Blocked(Exception):
    pass


def _is_interrupted() -> bool:
    from tools.interrupt import is_interrupted
    return is_interrupted()


def _policy_block(url: str) -> Optional[str]:
    """Hermes's SSRF and website-blocklist verdict for *url* (blocking DNS)."""
    from tools.url_safety import is_safe_url
    from tools.website_policy import check_website_access

    if not is_safe_url(url):
        return _UNSAFE_URL
    blocked = check_website_access(url)
    return blocked["message"] if blocked else None


async def _check(url: str) -> None:
    if message := await asyncio.to_thread(_policy_block, url):
        raise _Blocked(message)


def _entry(url: str, title: str, content: str, **metadata: Any) -> dict[str, Any]:
    return {
        "url": url, "title": title, "content": content, "raw_content": content,
        "metadata": {"sourceURL": url, "title": title, **metadata},
    }


def _error(url: str, error: str) -> dict[str, Any]:
    return {"url": url, "title": "", "content": "", "raw_content": "", "error": error}


def _html_title(html: str) -> str:
    match = re.search(r"<title[^>]*>(.*?)</title>", html, re.I | re.S)
    if not match:
        return ""
    import html as html_lib
    return re.sub(r"\s+", " ", html_lib.unescape(match.group(1))).strip()


_APP_SHELL = re.compile(
    r"<noscript|id=[\"'](?:root|app|__next|__nuxt|svelte)[\"']|data-reactroot|ng-version", re.I)


def _needs_browser(html: str) -> bool:
    """Whether a short page looks like a script-rendered app shell."""
    return bool(_APP_SHELL.search(html)) or len(re.findall(r"<script\b", html, re.I)) >= 3


def _from_html(html: str, url: str) -> tuple[str, str]:
    """(title, markdown) from an HTML document."""
    import trafilatura

    text = trafilatura.extract(
        html, url=url, output_format="markdown", include_links=True,
        include_tables=True, include_images=False, include_comments=False,
        favor_recall=True, deduplicate=True,
    ) or ""
    title = ""
    try:
        meta = trafilatura.extract_metadata(html, default_url=url)
        title = (meta.title if meta else "") or ""
    except Exception:
        pass
    return title or _html_title(html), text.strip()


def _from_pdf(data: bytes) -> tuple[str, str]:
    from pypdf import PdfReader

    reader = PdfReader(io.BytesIO(data))
    title = ""
    try:
        title = (reader.metadata.title or "") if reader.metadata else ""
    except Exception:
        pass
    pages = []
    for number, page in enumerate(reader.pages, 1):
        text = (page.extract_text() or "").strip()
        if text:
            pages.append(f"<!-- page {number} -->\n{text}")
    return title, "\n\n".join(pages)


def _decode(data: bytes, response: httpx.Response) -> str:
    try:
        return data.decode(response.encoding or "utf-8", errors="replace")
    except LookupError:
        return data.decode("utf-8", errors="replace")


_CHALLENGE = re.compile(
    r"just a moment|attention required|prove your humanity|verify (?:you are|you're) (?:a )?human"
    r"|are you a robot|access denied|security check|pardon our interruption|bot verification", re.I)


def _refusal(status: int) -> str:
    """Why a site refused both the direct fetch and the browser retry."""
    reason = {
        401: "The site requires a login",
        429: "Rate limited by the site",
    }.get(status, "Blocked by the site's bot protection")
    return f"{reason} (HTTP {status}); a browser retry was also refused. Try another source."


def _challenge(title: str, text: str) -> Optional[str]:
    """An error for a nearly empty page whose title is a bot challenge."""
    if len(text) < MIN_TEXT and _CHALLENGE.search(title or ""):
        return f"Blocked by the site's bot protection (challenge page: {title.strip()!r}). Try another source."
    return None


def _looks_like_pdf(content_type: str, url: str, data: bytes) -> bool:
    return "application/pdf" in content_type or data[:5] == b"%PDF-" or (
        not content_type and urlparse(url).path.lower().endswith(".pdf"))


class _Fetcher:
    """One extract call's HTTP client and, if needed, its browser."""

    def __init__(self) -> None:
        self._client = httpx.AsyncClient(
            follow_redirects=True, timeout=FETCH_TIMEOUT, max_redirects=8,
            headers={"User-Agent": USER_AGENT,
                     "Accept": "text/html,application/xhtml+xml,application/pdf;q=0.9,*/*;q=0.8",
                     "Accept-Language": "en-US,en;q=0.9"},
            # Check every hop, including redirects, before it is sent.
            event_hooks={"request": [lambda request: _check(str(request.url))]},
        )
        self._playwright = None
        self._browser = None
        self._browser_lock = asyncio.Lock()

    async def close(self) -> None:
        await self._client.aclose()
        if self._browser is not None:
            await self._browser.close()
        if self._playwright is not None:
            await self._playwright.stop()

    async def fetch(self, url: str) -> tuple[httpx.Response, bytes]:
        async with self._client.stream("GET", url) as response:
            chunks, size = [], 0
            async for chunk in response.aiter_bytes():
                size += len(chunk)
                if size > MAX_BYTES:
                    raise ValueError(f"Response is larger than {MAX_BYTES // (1024 * 1024)} MB")
                chunks.append(chunk)
            return response, b"".join(chunks)

    async def _get_browser(self):
        async with self._browser_lock:
            if self._browser is None:
                from playwright.async_api import async_playwright

                self._playwright = await async_playwright().start()
                executable = _chromium_executable()
                self._browser = await self._playwright.chromium.launch(
                    headless=True, executable_path=executable, chromium_sandbox=False,
                    args=["--disable-dev-shm-usage"])
            return self._browser

    async def render(self, url: str) -> tuple[str, str]:
        """(final URL, rendered HTML) from headless Chromium."""
        browser = await self._get_browser()
        context = await browser.new_context(user_agent=USER_AGENT, java_script_enabled=True)
        safe_hosts: dict[str, bool] = {}

        async def guard(route):
            request = route.request
            if request.resource_type in ("image", "media", "font"):
                return await route.abort()
            host = urlparse(request.url).hostname or ""
            if host not in safe_hosts:
                safe_hosts[host] = await asyncio.to_thread(_policy_block, request.url) is None
            if safe_hosts[host]:
                return await route.continue_()
            return await route.abort()

        try:
            await context.route("**/*", guard)
            page = await context.new_page()
            await page.goto(url, wait_until="domcontentloaded", timeout=RENDER_TIMEOUT * 1000)
            try:
                await page.wait_for_load_state("networkidle", timeout=5000)
            except Exception:
                pass  # Long-polling pages never go idle; use what has rendered.
            return page.url, await page.content()
        finally:
            await context.close()


def _chromium_executable() -> Optional[str]:
    """The Chromium bundled with Hermes, else Playwright's own lookup."""
    root = os.environ.get("PLAYWRIGHT_BROWSERS_PATH", "")
    found = sorted(glob.glob(os.path.join(root, "chromium-*", "chrome-linux*", "chrome"))) if root else []
    return found[-1] if found else None


async def _extract_one(fetcher: _Fetcher, url: str, want_html: bool) -> dict[str, Any]:
    try:
        await _check(url)
        status, final_url, content_type, data, response = 0, url, "", b"", None
        try:
            response, data = await fetcher.fetch(url)
            status, final_url = response.status_code, str(response.url)
            content_type = response.headers.get("content-type", "").split(";")[0].strip().lower()
        except (_Blocked, ValueError):
            raise
        except httpx.HTTPError as exc:
            logger.info("Iris fetch failed for %s, trying the browser: %s", url, exc)

        if response is not None and status < 400:
            if _looks_like_pdf(content_type, final_url, data):
                title, text = await asyncio.to_thread(_from_pdf, data)
                if not text:
                    return _error(final_url, "PDF has no extractable text (it may be scanned images)")
                return _entry(final_url, title, text, statusCode=status, contentType="application/pdf",
                              renderer="pdf")
            if content_type in _TEXT_TYPES or (content_type.startswith("text/") and "html" not in content_type):
                return _entry(final_url, "", _decode(data, response), statusCode=status,
                              contentType=content_type, renderer="text")
            html = _decode(data, response)
            if want_html:
                return _entry(final_url, _html_title(html), html, statusCode=status,
                              contentType=content_type, renderer="http")
            title, text = await asyncio.to_thread(_from_html, html, final_url)
            if (len(text) >= MIN_TEXT or (text and not _needs_browser(html))) and not _challenge(title, text):
                return _entry(final_url, title, text, statusCode=status, contentType=content_type,
                              renderer="http")
            fallback = (title, text)
        elif response is not None and status not in RENDER_STATUSES:
            return _error(final_url, f"HTTP {status}")
        else:
            fallback = None

        try:
            rendered_url, html = await asyncio.wait_for(fetcher.render(final_url), RENDER_TIMEOUT + 10)
        except _Blocked:
            raise
        except Exception as exc:
            logger.info("Iris browser render failed for %s: %s", final_url, exc)
            if fallback and fallback[1]:
                return _entry(final_url, *fallback, statusCode=status, contentType=content_type,
                              renderer="http")
            if status in RENDER_STATUSES:
                return _error(final_url, _refusal(status))
            return _error(final_url, f"HTTP {status}" if status else f"Fetch failed: {exc}")
        await _check(rendered_url)
        if want_html:
            return _entry(rendered_url, _html_title(html), html, renderer="browser")
        title, text = await asyncio.to_thread(_from_html, html, rendered_url)
        # A refused fetch that renders to almost nothing is a challenge page,
        # not the content the agent asked for.
        if status in RENDER_STATUSES and len(text) < MIN_TEXT:
            return _error(rendered_url, _refusal(status))
        if challenged := _challenge(title, text):
            return _error(rendered_url, challenged)
        if not text and fallback and fallback[1]:
            title, text = fallback
        if not text:
            return _error(rendered_url, "No readable text found on the page")
        return _entry(rendered_url, title, text, renderer="browser")
    except _Blocked as exc:
        return _error(url, str(exc))
    except Exception as exc:
        logger.debug("Iris extract failed for %s", url, exc_info=True)
        return _error(url, f"Extraction failed: {exc}")


class IrisWebProvider(WebSearchProvider):
    """Extract-only provider; pair it with a search backend such as SearXNG."""

    @property
    def name(self) -> str:
        return "iris"

    @property
    def display_name(self) -> str:
        return "Iris (local reader)"

    def is_available(self) -> bool:
        return all(importlib.util.find_spec(m) is not None for m in ("trafilatura", "pypdf"))

    def supports_search(self) -> bool:
        return False

    def supports_extract(self) -> bool:
        return True

    async def extract(self, urls: list[str], **kwargs: Any) -> list[dict[str, Any]]:
        """``format``: "html" returns page HTML; anything else returns markdown."""
        want_html = kwargs.get("format") == "html"
        fetcher = _Fetcher()
        limit = asyncio.Semaphore(max(1, CONCURRENCY))

        async def one(url: str) -> dict[str, Any]:
            if _is_interrupted():
                return _error(url, "Interrupted")
            async with limit:
                return await _extract_one(fetcher, url, want_html)

        try:
            return list(await asyncio.gather(*(one(str(u)) for u in urls)))
        finally:
            await fetcher.close()

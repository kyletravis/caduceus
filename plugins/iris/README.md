# Iris

A Hermes Agent `web_extract` provider that reads web pages locally, with no
separate service. Caduceus installs it during `hermes-init` and selects it
with `web.extract_backend: iris`.

For each URL, Iris:

1. checks the URL against Hermes's private-network and website-blocklist
   rules, and checks every redirect again;
2. fetches the page directly and turns HTML into markdown with
   [trafilatura](https://github.com/adbar/trafilatura), PDFs into text with
   [pypdf](https://github.com/py-pdf/pypdf), and returns other text as-is;
3. if the page is a script-rendered app shell, or the site refuses plain
   clients (401, 403, 406, 429, 503), renders it once in the headless
   Chromium bundled with Hermes and extracts again. The browser skips images,
   media and fonts and applies the same network rules to every subresource.

Requests for one call run concurrently. `metadata.renderer` records which path
served each page: `http`, `browser`, `pdf` or `text`.

| Variable | Default | Meaning |
|---|---|---|
| `IRIS_FETCH_TIMEOUT` | `20` | Seconds per direct fetch |
| `IRIS_RENDER_TIMEOUT` | `30` | Seconds per browser page load |
| `IRIS_MAX_BYTES` | 15 MB | Largest response Iris will read |
| `IRIS_CONCURRENCY` | `6` | Pages fetched at once per call |
| `IRIS_MIN_TEXT` | `400` | Below this many characters, an app shell is rendered in the browser |

Iris does not solve CAPTCHAs or log in to sites. When a site refuses it, the
page's `error` says why, so the agent can try another source:

- `Blocked by the site's bot protection (HTTP 403)` (also 406 and 503), when
  both the direct fetch and the browser retry were refused;
- `Blocked by the site's bot protection (challenge page: '…')`, when the site
  answered with a CAPTCHA or "checking your browser" page;
- `Rate limited by the site (HTTP 429)` and `The site requires a login (HTTP 401)`.

# Email Rendering Policy

Goal: render sender HTML as faithfully as Gmail/Mail while quietly blocking trackers and keeping layouts intact.

## Defaults
- Remote images **allowed** by default and eagerly inlined to data URIs (see Inline images).
- Tracking pixels stripped: remove 1–2 px images and common pixel filenames; hide `img[width|height<=2]`.
- Tracking parameters removed from links (`utm_*`, `mc_eid`, `fbclid`, etc.).

## Sanitization (HTMLSanitizer)
- Strip scripts, iframes, embeds, objects, forms, meta refresh, JS URLs, and external `<link rel=stylesheet>`.
- Remove zero‑width chars; drop tiny images; add `loading="lazy"` to `<img>` when absent.
- Block remote images only when the user has “Block remote images” enabled (convert `src` → `data-blocked-src`).

## CSS wrapper
- Minimal overrides; do **not** force backgrounds/colors.
- Keep email backgrounds: `body { background: transparent; color: inherit; }`.
- Preserve layout; responsive media only: `img { max-width: 100%; height: auto; }`, same for video/iframe/canvas.
- No forced padding; no anchor recolor; avoid hiding empty elements (some templating uses them).
- CSP: `img-src data: https: http: cid:; style-src 'unsafe-inline'; font-src data: https: http:; media-src https: http: data:; connect-src https: http:` (allows CID/HTTP/HTTPS assets).
- Upgrade `http://` asset URLs to `https://` where possible to satisfy ATS.
- Inline http(s) images and `background=` URLs to data URIs with a local cache (up to 20 images, 4 MB each, 8 MB total). This makes layouts resilient when CDNs block referers or the network is spotty—similar to Gmail/Mail’s proxying.
- Viewport set to 600 px desktop width to render fixed-width email templates identically to desktop; iOS auto-linking is disabled to avoid layout shifts.
- JavaScript stays disabled for sender content, but is enabled for a tiny built-in diagnostic script that reports missing images (naturalWidth == 0) back to Swift logs for debugging CDN/ATS issues.

## WebView behavior
- Content pre-sanitized off-main; WebView only loads final HTML string.
- Lazy-loading reduces initial jank; WebView is non-opaque with scroll disabled inside parent.

## User controls
- Global setting: block remote images (off by default).
- Per-message option can re-load with images unblocked if desired.

## Trade-offs
- External stylesheets are still removed (safety); most marketing emails inline critical CSS.
- Tiny-image removal may hide legitimate 1 px spacers; acceptable for privacy.

# Email Rendering Policy

Goal: render sender HTML as faithfully as Gmail/Mail while quietly blocking trackers and keeping layouts intact.

## Defaults
- Remote images **allowed** by default.
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
- No forced padding; no anchor recolor.
- CSP: `img-src data: https:`, `style-src 'unsafe-inline'` (matching common clients).

## WebView behavior
- Content pre-sanitized off-main; WebView only loads final HTML string.
- Lazy-loading reduces initial jank; WebView is non-opaque with scroll disabled inside parent.

## User controls
- Global setting: block remote images (off by default).
- Per-message option can re-load with images unblocked if desired.

## Trade-offs
- External stylesheets are still removed (safety); most marketing emails inline critical CSS.
- Tiny-image removal may hide legitimate 1 px spacers; acceptable for privacy.

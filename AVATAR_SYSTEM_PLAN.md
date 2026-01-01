# Avatar System Plan (Swift)

Goal: Build a robust, high‑match‑rate avatar system that avoids whack‑a‑mole rules by centralizing domain normalization, brand registry, caching, and contact lookup in a single resolver.

## Architecture

1) DomainNormalizer (single source of truth)
   - Parse email from "Name <email>".
   - Normalize gmail/googlemail plus‑tags (remove "+tag").
   - Normalize domain via alias map and root extraction (PSL list).

2) BrandRegistry (data, not code)
   - JSON registry (bundle resource):
     - personalDomains
     - domainAliases
     - logoOverrides
     - brandColors
     - publicSuffixes
   - Keeps brand logic out of the view.

3) AvatarService (resolver)
   - Resolve AvatarResolution with fallback order:
     contact photo → brand logo → initials.
   - Account‑scoped caches.
   - In‑flight de‑dupe (Task map).
   - TTL + LRU eviction.
   - Track brand logo success/failure per domain.

4) SmartAvatarView
   - Uses AvatarService.resolveAvatar(...)
   - Renders initials base + brand logo (if any), then contact photo.
   - Reports brand logo load success/failure to AvatarService.

## Implementation Steps

1) Add BrandRegistry JSON (Resources/brand_registry.json).
2) Update Package.swift to include processed resources.
3) Add DomainNormalizer.swift + BrandRegistry.swift.
4) Refactor AvatarService to:
   - Use BrandRegistry + DomainNormalizer.
   - Provide resolveAvatar + prefetch.
   - Account‑scoped cache, TTL + LRU, in‑flight tasks.
5) Update SmartAvatarView to use AvatarService only.
6) Wire in brand logo success/failure reporting.
7) Remove duplicated brand logic from views.

## Success Criteria

- No per‑sender rule updates needed for common domains.
- Correct personal vs brand behavior (gmail/googlemail never brand).
- No burst People API calls on list render.
- Stable avatar results across account switching.

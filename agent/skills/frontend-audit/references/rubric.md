# Audit rubric

Source: Chrome Modern Web Guidance, https://developer.chrome.com/docs/modern-web-guidance.
The categories map to that hub, its getting-started page, the modernization
workflow page and the guide catalog. Re-read the hub each run: the guidance
changes slowly, but the legacy-scan rules grow.

Score each frontend 0-10 per category (N/A when it truly does not apply, such
as no dialogs or no forms), then an overall 0-100. Scores are single-pass
judgment; a gap under 5 overall points is noise.

1. **baseline**: Baseline target declared in CLAUDE.md/AGENTS.md? browserslist
   or vite `build.target`? Non-widely-available features guarded by
   `@supports` or progressive enhancement?
2. **legacy** (the legacy-scan rules): JS `scrollHeight` textarea autosize
   (`field-sizing: content`); Enter keydown submit with no `isComposing` /
   keyCode 229 guard; `:invalid` styling on untouched inputs (`:user-invalid`);
   missing `autocomplete` on auth forms; `e.target === dialog` backdrop click
   (`<dialog closedby="any">`); JS click handlers that only toggle a popover
   (`popovertarget`); `max-height: 9999px` accordions (`interpolate-size` /
   `calc-size()`); JS parent class toggles from child state (`:has()`);
   duplicated `prefers-color-scheme` blocks (`light-dark()`); CDN script or
   link without `integrity` + `crossorigin`.
3. **overlays**: modals are native `<dialog>` (showModal, Esc, focus return)
   rather than div + teleport re-creations; scroll lock; popover API; anchor
   positioning for tooltips and dropdowns; `@starting-style` /
   `transition-behavior` / `overlay` for top-layer animation.
4. **css**: container queries, grid/subgrid, dvh/svh units,
   `light-dark()`/`color-scheme`, oklch, cascade layers and nesting,
   `text-wrap: balance|pretty`, forced-colors, `accent-color` /
   `scrollbar-color` theming of native UI.
5. **motion**: `prefers-reduced-motion` respected everywhere motion exists
   (spinners too); View Transitions for route changes; compositor-only
   animated properties.
6. **forms**: native controls styled (accent-color, switch, customizable
   select) rather than rebuilt widgets; validate after interaction;
   autocomplete tokens; IME-safe Enter.
7. **a11y**: semantic landmarks, labels, focus-visible, aria-live for errors
   and async status, keyboard navigation in grids and lists, labelled
   icon-only buttons, contrast and forced colors, table header semantics.
8. **perf**: route-level code splitting, image priority/lazy loading and
   dimensions, long tasks (`scheduler.yield`, chunking), virtualization for
   long lists, polling and background-fetch discipline, bundle weight.
9. **security**: `v-html` / `innerHTML` sinks and sanitization, Trusted Types
   and CSP, SRI on external assets, `rel=noopener`, referrer policy.

## Firefox is the primary browser

The Chrome guidance is a quality bar, not the target. For every suggested fix,
state Firefox support: shipped (with the version), behind a flag, not
supported, or "unsure" when unsure (check MDN, do not guess). A fix that
relies on a feature Firefox lacks may only be suggested as progressive
enhancement, with the fallback named.

Existing code that uses a Chromium-only feature with no fallback is a
**defect** and costs points. Examples: anchor positioning, `field-sizing`,
`interpolate-size`, `closedby`, invoker commands, `:has`-dependent behaviour
with no fallback. Also flag `-webkit-`-only CSS with no standard equivalent
(scrollbars are the usual one) and Chrome-only APIs.

## Priorities and effort

Fix `priority` is `high` (a real defect, a11y blocker, or Firefox-visible
problem), `med`, or `low`. `effort` is S, M or L. Every fix cites file:line as
the reviewer saw it; lines may have moved by the time someone works the fix.

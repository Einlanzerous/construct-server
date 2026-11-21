# REVIEW.md Frontend block

Paste this under a "Frontend" heading in each frontend repo's `REVIEW.md`. The
CI reviewer applies it to diffs that touch `.vue`, `.css`, `.html` or
component TypeScript. Firefox is the primary browser.

## Frontend

For diffs that touch UI, check:

- Motion (transitions, animations, spinners) is gated on
  `prefers-reduced-motion`.
- Modals use `<dialog>` and `showModal()`, not a div with a scrim.
- Enter key handlers guard `isComposing`.
- No `outline: none` without a replacement `:focus-visible` ring.
- New CSS features are shipped in Firefox, or sit behind `@supports` with a
  working fallback.
- No `::-webkit-` rule without its standard property (for example scrollbars
  need `scrollbar-width` / `scrollbar-color`).

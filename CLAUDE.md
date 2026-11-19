# Pigeon Post — Koha email activity dashboard (koha.pro plugin)

Tools → "Pigeon Post Dashboard". Perl namespace `Koha::Plugin::Pro::Koha::PigeonPost`, author `koha.pro`.
Targets Koha 22.11+.

## Styling rule: match koha.pro (RustSearch page)
All plugin UI (dashboard, configure page, weekly digest email, SVG logo, charts) follows the styling
concepts of **https://koha.pro/rustsearch/**. The live stylesheet is identical to the local copy at
`../rustsearch/rustsearch-promo/dist/styles.css` (checked 2026-11-19); read it for exact patterns.
If the live page changes, update these tokens first, then the plugin CSS.

Brand tokens (CSS custom properties scoped under `.pigeon` so Koha's staff CSS is untouched):

| Token | Value | Use |
|---|---|---|
| `--pp-navy` | `#002f65` | top bar, dark "evidence" band, table header highlight, headings in cards |
| `--pp-blue` | `#07448f` | primary buttons, links, eyebrow labels, "sent" series, active bars |
| `--pp-ink` | `#142033` | body text |
| `--pp-muted` | `#607086` | secondary text, captions, axis labels |
| `--pp-line` | `#d7e0eb` | card/table borders, dividers |
| `--pp-wash` | `#f3f7fc` | page background |
| `--pp-accent` | `#7ec9ff` | brand-name accent on navy, highlights |
| `--pp-light` | `#b7dfff` | big numbers on the navy band |
| `--pp-light-sub` | `#c8d8ed` | body text on the navy band |
| `--pp-bar-track` / `--pp-bar-fill` | `#edf2f8` / `#b6cde6` | inactive bar track/fill (active fill = `--pp-blue`) |
| `--pp-pilot-bg` / `--pp-pilot-border` | `#e7f0fa` / `#cdddec` | soft blue callout band |
| `--pp-thead` | `#f3f6fa` | table header background |
| `--pp-radius` | `10px` | base radius |

Status colors: up/OK `#16855c` (the site's status dot, label text `#357259`);
warning/slow uses the site's "hold" pattern: border `#d7b76f`, background `#fff8e9`, accent `#b28b37`;
down/failed `#c8463d` (not on the site; chosen to sit with the palette, use sparingly).
Charts: "sent" `#07448f`, "failed" `#c8463d`, other series `#b6cde6`, `#7ec9ff`, `#002f65`, `#607086`.
Gridlines `#edf2f8`, axis text `--pp-muted`, no chart borders, tabular numerals.

Shapes and type:
- Font: `Inter, ui-sans-serif, system-ui, -apple-system, "Segoe UI", sans-serif`. Do not load web fonts
  (Inter is used only if installed); line-height 1.6.
- Headings heavy (700–760) with negative letter-spacing (h2 about -1.6px at ~34–39px; card h3 ~18–19px, -0.4px).
- Eyebrow labels: ~10px, weight 750, letter-spacing 1.7px, uppercase, `--pp-blue` (on navy: `#8fc8ff`).
- Header: navy `.topbar` band with brand wordmark (weight 800, -1.2px; second word in `--pp-accent`).
- Buttons: radius 5px, weight 650, 13px, padding 13px 18px. Primary = `--pp-blue` fill, hover `--pp-navy`
  with shadow `0 4px 15px #002f6520`. Secondary = white with `--pp-line` border, `--pp-blue` text.
- Cards/panels: white, 1px `--pp-line`, radius 9–10px, padding ~25px, little or no shadow.
- Key metrics: big number in `--pp-navy` (~39px, -1.6px, weight 700) with a small muted caption.
  The headline KPI row can sit on a navy band (numbers in `--pp-light`, separators `#ffffff26`).
- Bar lists: `.bar-row` grid (label | 9px track radius 2px | right-aligned tabular number).
- Tables: inside an `overflow-x:auto` wrapper with 1px `--pp-line` border, radius 9px; `--pp-thead` header.
- Status: small 6px round dot + uppercase micro-label (green / amber / red as above).
- Focus: visible outline (3px solid `--pp-accent`, offset 3px).
- The digest email uses the same palette with inline styles (email clients ignore CSS variables):
  a navy header band, white cards on `#f3f7fc`, and `#07448f` links.

## Data-safety rules
- Read Koha tables only through placeholders. Never write Koha core tables except:
  - clearing a patron email field via `Koha::Patrons` (explicit click or opted-in auto mode);
  - marking that address's pending `message_queue` rows `status='deleted'` (never DELETE);
  - for patrons with no address Koha can email (per `EmailFieldPrimary`), moving their
    `borrower_message_transport_preferences` rows from `email` to `print`/`sms` (Prefs.pm), only on an
    explicit click or as the opted-in follow-up to an address clear. Re-check "no address" at write time,
    only add a transport the notice offers in `message_transports`, run each patron in a transaction, and
    log the exact rows changed so undo can restore them.
- Plugin-owned tables only: `_daily_stats`, `_cleanup_log`, `_prefs_log` (via `get_qualified_table_name`).
  `uninstall` drops only these.
- Auto-cleanup must keep the outage guard (skip when >50% of last-24h sends failed) and the per-run cap.
- Test on a disposable koha-testing-docker instance, never production.

## Commands
- Unit tests (pure Perl, no Koha needed): `prove -l t/`
- Build KPZ: `tools/build_kpz.sh` → `dist/pigeon-post-v<version>.kpz`
- Seed test data on a KTD instance: `perl tools/seed_fixtures.pl` (inside the KTD container)

# Addition-event ground truth spike (#1115)

**Date:** 2026-06-12 · **DB:** `cinegraph_dev`

Built `list_membership_events` — one row per (list, movie, add/remove event) — to give
the prediction product the addition-event ground truth it lacked (the DB previously held
only current-union membership). Session scope: NFR + 1001_movies. No eval/model/grading
code touched.

## Per-list coverage

| list | found | matched | pending | adds/removes | net-adds vs current |
|---|--:|--:|--:|--:|--:|
| national_film_registry | 928 | 833 | 95 | / | 833 vs 900 |

## Notes, caps, and gaps

- **national_film_registry**: events_found=928 cross_check="loc+wikipedia" wikipedia_only=34 loc_only=31

## Acceptance-gate status

- **NFR induction-year add-events: DONE.** 928 events populated, 833 matched (90%),
  95 pending (kept, never dropped). Spot-checks vs known NFR facts all correct:
  Casablanca/Citizen Kane → `nfr_1989` (inaugural class), Pulp Fiction → `nfr_2013`,
  Toy Story → `nfr_2005`, The Shining → `nfr_2018`, Do the Right Thing → `nfr_1999`.
  The release-year ↔ induction-year separation — the core deliverable — works.
- Reconciliation: net matched adds 833 vs 900 current canonical members → discrepancy
  −67. Listed, not hidden: 67 NFR-canonical movies in the DB did not title-match the
  Wikipedia scrape (title variants, e.g. "Star Wars" listed under a longer title) and
  95 events stayed pending. A `--rematch-pending` pass + imdb-id backfill recovers most.
- No eval/model/grading file touched.

## Source reconnaissance — why only NFR landed this session

Live recon (2026-06-12) on every in-scope source. NFR is the **only** one that exposes
the film list as clean, server-rendered HTML. The other four return HTTP 200 but do
**not** contain the list in parseable HTML — each needs a bespoke extraction strategy,
not an HTML-table parser. This is the "messy edition sourcing → second session" case the
issue (#1115) explicitly anticipated.

| source | sources probed | finding | what it actually needs |
|---|---|---|---|
| **national_film_registry** | Wikipedia + loc.gov | ✅ clean static `<table>` (titles in `<th>` on loc.gov) | **done** |
| **1001_movies** | Fandom `The List`, icheckmovies | Fandom behind Cloudflare; Crawlbase normal mode returns a **challenge page** (`:challenge`), not content. No HTML tables. icheckmovies 403. | Crawlbase **JS** mode (costlier, uncertain) or a confirmed structured source (CSV/JSON dataset) |
| **tspdt_1000** | archive.org Wayback of `gf1000.htm` | snapshots are a JS-frame shell (25 KB, top-10 preview only); real 1000-film list loads via AJAX/PHP frame or lives in `.xls`/`.ods` files | JSON-endpoint reverse-engineering **or** historical Excel parsing |
| **criterion** | criterion.com spine list | React/JS site, WAF-gated (403 direct) | Crawlbase JS mode + JSON/`__NEXT_DATA__` extraction |
| **letterboxd_top_250** | archive.org Wayback of the Top-250 list | snapshot HTML is minimal — the poster grid is lazy-loaded/paginated, not in captured markup | JS rendering or per-page pagination crawl |

**The pipeline is source-agnostic and ready:** schema, context, `MovieMatcher`, import
maintenance module, and mix task are all built and unit-tested; the `Movies1001Scraper`
diff engine is built and tested too. Each remaining source just needs its own
fetch+parse module slotted into the dispatcher — and a fetch strategy matched to its
real (JS/Excel/JSON) delivery, decided per source rather than assumed to be HTML.

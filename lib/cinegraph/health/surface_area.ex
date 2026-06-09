defmodule Cinegraph.Health.SurfaceArea do
  @moduledoc """
  One terminal-state coverage row per external data source (#1090 Phase 0).

  Unifies the three fragmented lenses (`predictions.audit_coverage`, `cinegraph.completeness`,
  `Health.Drift`) into a single table the surface-area tracker pings. Each fetchable source
  reports the #1053 terminal-state shape:

    * `eligible` — the denominator (e.g. OMDb = movies with an `imdb_id`; bounds the universe)
    * `fetched` — we have the data (blob/value present)
    * `source_absent` — we tried, the source had nothing (recent `fetch_attempt`, within cooldown)
    * `needs_fetch` — eligible ∧ no data ∧ no recent attempt ← the only true API backlog
    * `materialization_debt` — blob present but derivable rows missing (OMDb only, via `OmdbParity`)
    * `terminal_pct` — `(fetched + source_absent) / eligible` — the "done" number

  Computed/supplemental sources (collaborations, PQS, stock images, Wikidata) appear as rows
  too, marked `kind: :computed | :supplemental` with nil coverage — the table is complete per
  "one row per source" but never fabricates a number for things that aren't a fetch backlog.

  Reuses (no forked SQL): `Cinegraph.Maintenance.BackfillOmdb.needs_fetch/2` (the shared OMDb
  needs-fetch predicate, same one `Drift.Movies.missing_omdb` uses) and
  `Cinegraph.Metrics.OmdbParity.gaps/1`. This is the reusable context the future
  `/admin/surface_area` dashboard (#1090 Phase 4) will read from.
  """

  import Ecto.Query

  alias Cinegraph.Health.Scopes
  alias Cinegraph.Maintenance.BackfillOmdb
  alias Cinegraph.Metrics.OmdbParity
  alias Cinegraph.Repo

  @doc "Compute the full surface-area report. Reads via the replica (heavy analysis)."
  def report do
    %{
      generated_at: DateTime.utc_now(),
      sources: [
        # §2 #1, #2 — TMDb import spine + metrics
        tmdb_details_row(),
        tmdb_metrics_row(),
        # §2 #3 — people (canonical-scoped)
        people_row("people_biography", :biography),
        people_row("people_profile_path", :profile_path),
        # §2 #4, #5 — availability + theatrical
        watch_providers_row(),
        now_playing_row(),
        # §2 #2 (cont.) — TMDb budget/revenue (thin at source; their own rows per review)
        derived_metric_row("tmdb_budget", "tmdb", "budget", fn n ->
          "#{n} materialized; ~77.8k present in TMDb (≈8.9k recoverable debt), rest source-absent"
        end),
        derived_metric_row("tmdb_revenue", "tmdb", "revenue_worldwide", fn n ->
          "#{n} materialized; ~26.2k present in TMDb (≈done), rest source-absent"
        end),
        # §2 #6 — OMDb (flagship)
        omdb_row(),
        # §2 #7, #8 — RT + Metacritic (OMDb-derived)
        derived_metric_row("rotten_tomatoes", "rotten_tomatoes", "tomatometer", fn n ->
          "via OMDb; #{n} movies have a tomatometer — low coverage is source-absence, not a backlog"
        end),
        derived_metric_row("metacritic", "metacritic", "metascore", fn n ->
          "via OMDb; #{n} movies have a metascore — low coverage is source-absence, not a backlog"
        end),
        # §2 #9, #10 — canonical lists + IMDb-ID coverage
        canonical_lists_row(),
        imdb_id_row(),
        # §2 #11 — festivals (person linkage is the live gap)
        festival_person_link_row(),
        # §2 #12–#15 — computed & supplemental
        computed_row("collaborations", "co-appearance graph — computed, not a fetch backlog"),
        computed_row(
          "person_quality_scores",
          "PQS — computed weekly/monthly, not a fetch backlog"
        ),
        supplemental_row("stock_images", "poster fallbacks — on-demand only"),
        supplemental_row("wikidata", "name/ID verification — supplemental, no direct writes")
      ]
    }
  end

  # ── OMDb (the flagship terminal-state source) ─────────────────────────────────────
  defp omdb_row do
    eligible = count(from m in "movies", where: not is_nil(m.imdb_id) and m.imdb_id != "")

    fetched =
      count(
        from m in "movies",
          where: not is_nil(m.imdb_id) and m.imdb_id != "" and not is_nil(m.omdb_data)
      )

    needs_fetch =
      "movies"
      |> BackfillOmdb.needs_fetch()
      |> where([m], not is_nil(m.imdb_id) and m.imdb_id != "")
      |> count_query()

    # eligible partitions into: fetched (have blob) | source_absent (no blob, recent attempt) |
    # needs_fetch (no blob, no recent attempt). So source_absent is the remainder.
    source_absent = max(eligible - fetched - needs_fetch, 0)
    debt = OmdbParity.gaps(Repo.replica()) |> Enum.map(& &1.gap) |> Enum.sum()

    fetch_row("omdb", eligible, fetched, source_absent, needs_fetch,
      debt: debt,
      target: 99.5,
      note: "ceiling: only IMDb-ID-bearing movies are eligible (#1090 — TMDb long tail has none)"
    )
  end

  # ── TMDb movie details (the import spine — no fetch_attempt concept) ───────────────
  defp tmdb_details_row do
    eligible = count(from(m in "movies"))
    fetched = count(from m in "movies", where: not is_nil(m.tmdb_data))

    fetch_row("tmdb_details", eligible, fetched, nil, max(eligible - fetched, 0),
      note: "one-shot import; never re-fetched (#1010 freshness gap)"
    )
  end

  # ── TMDb metrics (§2 #2) — ratings/votes/popularity/budget/revenue from external_metrics ──
  defp tmdb_metrics_row do
    eligible = count(from m in "movies", where: not is_nil(m.tmdb_data))

    fetched =
      Repo.replica().one(
        from(e in "external_metrics",
          where: e.source == "tmdb",
          select: count(e.movie_id, :distinct)
        )
      ) || 0

    # The gap is source-absent (voteless films): a one-time scan found only ~205 of the ~230k
    # "missing" have a vote_count to derive from. So treat the gap as source-absent → ~terminal.
    fetch_row("tmdb_metrics", eligible, fetched, max(eligible - fetched, 0), 0,
      note:
        "gap is voteless films (source-absent; one-time scan: only ~205 derivable) → ~terminal"
    )
  end

  # ── TMDb now playing (§2 #5) — ephemeral theatrical, not a backlog ────────────────
  defp now_playing_row do
    nil_row("now_playing", :ephemeral, "current theatrical (5 regions); polled, not a backlog")
  end

  # ── RT / Metacritic (§2 #7/#8) — OMDb-derived; low coverage is source-absence ──────
  # A derived/informational row: just the materialized-row count + a characterization note.
  # No terminal% — these are source-absent-dominated (OMDb-derived RT/Metacritic, TMDb-thin
  # budget/revenue), so a coverage % would imply a backlog that doesn't exist.
  defp derived_metric_row(label, source, metric_type, note_fn) do
    have =
      Repo.replica().one(
        from(e in "external_metrics",
          where: e.source == ^source and e.metric_type == ^metric_type,
          select: count(e.movie_id, :distinct)
        )
      ) || 0

    %{
      source: label,
      kind: :derived,
      eligible: nil,
      fetched: have,
      source_absent: nil,
      needs_fetch: nil,
      materialization_debt: nil,
      terminal_pct: nil,
      target: nil,
      note: note_fn.(have)
    }
  end

  # ── IMDb-ID coverage (§2 #10) — the OMDb-eligibility ceiling ──────────────────────
  defp imdb_id_row do
    # Denominator PINNED to all movies (1.16M) for dashboard self-consistency. This is a
    # structural ceiling (TMDb returns null for the long tail) — no target, not a backlog.
    eligible = count(from(m in "movies"))
    fetched = count(from m in "movies", where: not is_nil(m.imdb_id) and m.imdb_id != "")

    fetch_row("imdb_id", eligible, fetched, nil, max(eligible - fetched, 0),
      note: "TMDb long tail has no IMDb ID at source — recovery yield ≈ 0 (#1090 ceiling)"
    )
  end

  # ── People biography / profile_path (CANONICAL-scoped) ────────────────────────────
  # Scoped to people credited on a canonical-list movie — matching `Drift.People`, which
  # documents that full-population people coverage is "a meaningless 100% RED" artifact
  # (bulk imports never fetch bios/photos for the long tail). Reporting full-pop here would
  # mis-prioritize Phase 3 (a 1.3% full-pop biography number is noise, not a backlog).
  defp people_row(label, field) do
    eligible = Scopes.canonical_people_count()

    fetched =
      Repo.replica().one(
        from p in "people",
          join: mc in "movie_credits",
          on: mc.person_id == p.id,
          join: m in "movies",
          on: m.id == mc.movie_id,
          where: fragment("? != '{}'::jsonb", m.canonical_sources),
          where: not is_nil(field(p, ^field)) and field(p, ^field) != "",
          select: count(p.id, :distinct)
      ) || 0

    # biography → "terminal post-substrate" (needs fetch_attempt tracking, S3) so no numeric
    # target yet; profile is essentially done → 95.
    target = if field == :profile_path, do: 95.0, else: nil

    fetch_row(label, eligible, fetched, nil, max(eligible - fetched, 0),
      target: target,
      note:
        "canonical-scoped (credited on a canonical-list movie)" <>
          if(field == :biography,
            do: " — target: terminal once fetch_attempt tracking lands (S3)",
            else: ""
          )
    )
  end

  # ── Festival nomination → person linkage (#873) ───────────────────────────────────
  # Scoped to person-TRACKED categories only (join festival_categories, tracks_person=true) —
  # film-only categories (Best Picture, etc.) have no person nominee and must not count as a
  # failed link. Matches Drift.People.person_required_nomination_missing_person + AwardPersonLinkage.
  defp festival_person_link_row do
    base =
      from n in "festival_nominations",
        join: c in "festival_categories",
        on: n.category_id == c.id,
        where: c.tracks_person == true

    eligible = count_query(base)
    fetched = count_query(where(base, [n, _c], not is_nil(n.person_id)))

    fetch_row("festival_person_link", eligible, fetched, nil, max(eligible - fetched, 0),
      target: 95.0,
      note:
        "person-tracked categories only (#873) — gap is ~100% empty-payload (resolver recovers 0); needs reimport, not resolution"
    )
  end

  # ── Watch providers (has its own freshness ledger) ────────────────────────────────
  # Eligible = the AvailabilityRefreshSweeper's actual target (full + tmdb_id). status semantics:
  # success = have providers (fetched); no_results = source-absent; error = unresolved. The 914k
  # target is deliberate (#1096 decision) — most of it is the long tail, so this is a genuine
  # cap-bound backlog, not a denominator artifact; canonical is the high-value subset.
  defp watch_providers_row do
    eligible =
      count(from m in "movies", where: m.import_status == "full" and not is_nil(m.tmdb_id))

    success = avail_movies(["success"])
    resolved = avail_movies(["success", "no_results"])
    source_absent = max(resolved - success, 0)
    needs = max(eligible - resolved, 0)

    canon_total = Scopes.canonical_movies_count()

    canon_success =
      Repo.replica().one(
        from r in "movie_availability_refreshes",
          join: m in "movies",
          on: m.id == r.movie_id,
          where: r.status == "success" and fragment("? != '{}'::jsonb", m.canonical_sources),
          select: count(r.movie_id, :distinct)
      ) || 0

    canon_pct = if canon_total > 0, do: Float.round(canon_success * 100 / canon_total, 1)

    fetch_row("watch_providers", eligible, success, source_absent, needs,
      target: 95.0,
      note:
        "sweeper targets all full+tmdb_id; ~#{needs} unattempted at 5k/day — cap is the bottleneck (#760); canonical subset #{canon_pct}%"
    )
  end

  defp avail_movies(statuses) do
    Repo.replica().one(
      from r in "movie_availability_refreshes",
        where: r.status in ^statuses,
        select: count(r.movie_id, :distinct)
    ) || 0
  end

  # ── Canonical lists (list-level coverage, different shape) ─────────────────────────
  defp canonical_lists_row do
    rows =
      Repo.replica().all(
        from ml in "movie_lists",
          where: ml.active == true,
          select: %{
            key: ml.source_key,
            members:
              fragment(
                "(SELECT count(*) FROM movies m WHERE m.canonical_sources \\? ?)",
                ml.source_key
              )
          }
      )

    eligible = length(rows)
    fetched = Enum.count(rows, &(&1.members > 0))

    fetch_row("canonical_lists", eligible, fetched, nil, max(eligible - fetched, 0),
      note: "list-level: active lists with ≥1 member; true-count accuracy tracked in #965"
    )
  end

  # ── row builders ──────────────────────────────────────────────────────────────────
  defp fetch_row(source, eligible, fetched, source_absent, needs_fetch, opts) do
    terminal =
      if eligible && eligible > 0 do
        Float.round((fetched + (source_absent || 0)) * 100 / eligible, 2)
      end

    %{
      source: source,
      kind: :fetch,
      eligible: eligible,
      fetched: fetched,
      source_absent: source_absent,
      needs_fetch: needs_fetch,
      materialization_debt: Keyword.get(opts, :debt),
      terminal_pct: terminal,
      target: Keyword.get(opts, :target),
      note: Keyword.get(opts, :note)
    }
  end

  defp computed_row(source, note), do: nil_row(source, :computed, note)
  defp supplemental_row(source, note), do: nil_row(source, :supplemental, note)

  defp nil_row(source, kind, note) do
    %{
      source: source,
      kind: kind,
      eligible: nil,
      fetched: nil,
      source_absent: nil,
      needs_fetch: nil,
      materialization_debt: nil,
      terminal_pct: nil,
      target: nil,
      note: note
    }
  end

  # ── helpers ─────────────────────────────────────────────────────────────────────
  defp count(queryable), do: queryable |> count_query()

  defp count_query(query) do
    Repo.replica().one(from(q in exclude(query, :select), select: count())) || 0
  end
end

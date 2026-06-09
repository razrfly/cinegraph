defmodule Cinegraph.Maintenance.BackfillFreshness do
  @moduledoc """
  Seed the `data_refreshes` ledger from signals we already record (#1096 Phase B /
  #1090 §1d) — no API calls. This is what makes the §4b provenance matrix go
  all-✅ on freshness: the freshness-blind sources (TMDb details, people) get a
  freshness signal for the first time, and the ledger gets a day-0 baseline.

  Idempotent (`INSERT … ON CONFLICT DO NOTHING`), **chunked by id-range with
  sleeps** (the #929 replica/pool lesson), resumable. Seeds **positive signals
  only** — rows where we already have a `fetched_at`/`scraped_at`/attempt; it does
  not synthesize "never-fetched" rows for the whole catalog (those eligible-but-
  unfetched gaps are the surface-area backlog, and the live `touch()` calls fill
  the ledger as the sweepers fetch them).

  `insert_all` does NOT cast (the #1089 lesson): every value here is already the
  column's type (`DateTime` truncated to second, integer ids, string statuses),
  and `inserted_at`/`updated_at` are set explicitly.

  Run all sources, or a subset:

      Cinegraph.Maintenance.BackfillFreshness.run()
      Cinegraph.Maintenance.BackfillFreshness.run(only: [:omdb, :tmdb_details])
  """
  import Ecto.Query
  require Logger

  alias Cinegraph.Freshness.Policy
  alias Cinegraph.Repo

  @sources [:tmdb_details, :omdb, :watch_providers, :tmdb_person, :festivals, :lists]
  @chunk 10_000
  @sleep_ms 50
  # Postgres caps a statement at 65_535 bind params; each row binds 8 columns.
  # Keep insert sub-batches well under that (4_000 × 8 = 32_000).
  @max_insert_rows 4_000

  def run(opts \\ []) do
    only = Keyword.get(opts, :only, @sources)

    results =
      for source <- @sources, source in only, into: %{} do
        {source, run_source(source, opts)}
      end

    {:ok, results}
  end

  defp run_source(:tmdb_details, opts), do: backfill_tmdb_details(opts)
  defp run_source(:omdb, opts), do: backfill_omdb(opts)
  defp run_source(:watch_providers, opts), do: backfill_watch_providers(opts)
  defp run_source(:tmdb_person, opts), do: backfill_tmdb_person(opts)
  defp run_source(:festivals, opts), do: backfill_festivals(opts)
  defp run_source(:lists, opts), do: backfill_lists(opts)

  # --- movie / tmdb_details: every full movie → ok, anchored on updated_at ----
  defp backfill_tmdb_details(opts) do
    max_id = max_id("movies")

    chunk(max_id, opts, fn lo, hi ->
      from(m in "movies",
        where: m.import_status == "full" and m.id >= ^lo and m.id < ^hi,
        select: %{id: m.id, release_date: m.release_date, updated_at: m.updated_at}
      )
      |> Repo.replica().all()
      |> Enum.map(fn m ->
        fetched = to_utc(m.updated_at)

        ledger_row(
          "movie",
          m.id,
          "tmdb_details",
          "ok",
          fetched,
          stale(:movie_age, "tmdb_details", m.release_date, fetched, :ok)
        )
      end)
    end)
  end

  # --- movie / omdb: blob-present → ok; fetch_attempt → empty -----------------
  defp backfill_omdb(opts) do
    max_id = max_id("movies")

    fetched_count =
      chunk(max_id, opts, fn lo, hi ->
        from(m in "movies",
          where:
            not is_nil(m.omdb_data) and not is_nil(m.imdb_id) and m.imdb_id != "" and
              m.id >= ^lo and m.id < ^hi,
          select: %{id: m.id, release_date: m.release_date, updated_at: m.updated_at}
        )
        |> Repo.replica().all()
        |> Enum.map(fn m ->
          fetched = to_utc(m.updated_at)

          ledger_row(
            "movie",
            m.id,
            "omdb",
            "ok",
            fetched,
            stale(:movie_age, "omdb", m.release_date, fetched, :ok)
          )
        end)
      end)

    # fetch_attempt rows → :empty (run after :ok so a blob-present movie keeps ok)
    empty_count =
      chunk(max_id, opts, fn lo, hi ->
        from(em in "external_metrics",
          join: m in "movies",
          on: m.id == em.movie_id,
          where:
            em.source == "omdb" and em.metric_type == "fetch_attempt" and
              em.movie_id >= ^lo and em.movie_id < ^hi and is_nil(m.omdb_data),
          select: %{id: em.movie_id, release_date: m.release_date, attempted_at: em.fetched_at}
        )
        |> Repo.replica().all()
        |> Enum.map(fn m ->
          anchor = to_utc(m.attempted_at) || now()
          # empty = source had nothing; never successfully fetched (fetched_at nil)
          ledger_row(
            "movie",
            m.id,
            "omdb",
            "empty",
            nil,
            stale(:movie_age, "omdb", m.release_date, anchor, :empty)
          )
        end)
      end)

    %{fetched: fetched_count, empty: empty_count}
  end

  # --- movie / watch_providers: collapse per-region availability rows ---------
  defp backfill_watch_providers(opts) do
    max_id = max_id("movie_availability_refreshes")

    chunk(max_id, opts, fn lo, hi ->
      from(r in "movie_availability_refreshes",
        where: r.id >= ^lo and r.id < ^hi,
        group_by: r.movie_id,
        select: %{
          movie_id: r.movie_id,
          fetched_at: max(r.fetched_at),
          stale_after: max(r.stale_after),
          any_success: fragment("bool_or(? = 'success')", r.status),
          any_no_results: fragment("bool_or(? = 'no_results')", r.status)
        }
      )
      |> Repo.replica().all()
      |> Enum.map(fn r ->
        status =
          cond do
            r.any_success -> "ok"
            r.any_no_results -> "empty"
            true -> "error"
          end

        ledger_row(
          "movie",
          r.movie_id,
          "watch_providers",
          status,
          to_utc(r.fetched_at),
          to_utc(r.stale_after)
        )
      end)
    end)
  end

  # --- person / tmdb_person: canonical-credited people ------------------------
  # bio present → ok; bio missing → pending (so Phase C can mark source-absent).
  defp backfill_tmdb_person(opts) do
    max_id = max_id("people")

    chunk(max_id, opts, fn lo, hi ->
      from(p in "people",
        where:
          p.id >= ^lo and p.id < ^hi and not is_nil(p.tmdb_id) and
            fragment(
              "EXISTS (SELECT 1 FROM movie_credits mc JOIN movies m ON m.id = mc.movie_id WHERE mc.person_id = ? AND m.canonical_sources != '{}'::jsonb)",
              p.id
            ),
        select: %{id: p.id, biography: p.biography, updated_at: p.updated_at}
      )
      |> Repo.replica().all()
      |> Enum.map(fn p ->
        if blank?(p.biography) do
          # never usefully fetched → pending, due now (drained by the floor in Phase C)
          ledger_row("person", p.id, "tmdb_person", "pending", nil, now())
        else
          fetched = to_utc(p.updated_at)

          ledger_row(
            "person",
            p.id,
            "tmdb_person",
            "ok",
            fetched,
            stale(:person_age, "tmdb_person", nil, fetched, :ok)
          )
        end
      end)
    end)
  end

  # --- festival_event / year_discovery: ceremonies by scraped_at --------------
  defp backfill_festivals(opts) do
    max_id = max_id("festival_ceremonies")

    chunk(max_id, opts, fn lo, hi ->
      from(c in "festival_ceremonies",
        where: c.id >= ^lo and c.id < ^hi and not is_nil(c.scraped_at),
        select: %{id: c.id, scraped_at: c.scraped_at}
      )
      |> Repo.replica().all()
      |> Enum.map(fn c ->
        fetched = to_utc(c.scraped_at)

        ledger_row(
          "festival_event",
          c.id,
          "year_discovery",
          "ok",
          fetched,
          stale(:fixed, "year_discovery", nil, fetched, :ok)
        )
      end)
    end)
  end

  # --- list / imdb_list: movie_lists by last_import_at ------------------------
  defp backfill_lists(opts) do
    max_id = max_id("movie_lists")

    chunk(max_id, opts, fn lo, hi ->
      from(l in "movie_lists",
        where: l.id >= ^lo and l.id < ^hi and not is_nil(l.last_import_at),
        select: %{id: l.id, last_import_at: l.last_import_at, status: l.last_import_status}
      )
      |> Repo.replica().all()
      |> Enum.map(fn l ->
        fetched = to_utc(l.last_import_at)
        status = if l.status in ["failed", "error"], do: "error", else: "ok"

        ledger_row(
          "list",
          l.id,
          "imdb_list",
          status,
          fetched,
          stale(:fixed, "imdb_list", nil, fetched, :ok)
        )
      end)
    end)
  end

  # --- shared ----------------------------------------------------------------

  defp stale(_kind, _source, _base_date, nil, _status), do: now()

  defp stale(:movie_age, source, base_date, anchor, status),
    do: Policy.stale_after("movie", source, base_date, anchor, status: status)

  defp stale(:person_age, source, base_date, anchor, status),
    do: Policy.stale_after("person", source, base_date, anchor, status: status)

  defp stale(:fixed, "imdb_list", base_date, anchor, status),
    do: Policy.stale_after("list", "imdb_list", base_date, anchor, status: status)

  defp stale(:fixed, "year_discovery", base_date, anchor, status),
    do: Policy.stale_after("festival_event", "year_discovery", base_date, anchor, status: status)

  defp ledger_row(entity_type, entity_id, source, status, fetched_at, stale_after) do
    n = now()

    %{
      entity_type: entity_type,
      entity_id: entity_id,
      source: source,
      status: status,
      fetched_at: fetched_at,
      stale_after: stale_after,
      inserted_at: n,
      updated_at: n
    }
  end

  # Insert one chunk's builder output; ON CONFLICT DO NOTHING makes it idempotent.
  #
  # `:min_id`/`:max_id` bound the id window so the heavy sources (omdb ~640k,
  # tmdb_details ~1.1M) can be backfilled in segments — a single full-table eval
  # OOM/timeout-kills the constrained prod box (hit 2026-06-09). Segmenting keeps
  # each run short and low-memory; ON CONFLICT makes segments overlap-safe.
  defp chunk(max_id, opts, builder) do
    step = Keyword.get(opts, :chunk, @chunk)
    sleep = Keyword.get(opts, :sleep_ms, @sleep_ms)
    lo_start = Keyword.get(opts, :min_id, 0)
    hi_end = min(max_id, Keyword.get(opts, :max_id) || max_id)

    if lo_start > hi_end do
      0
    else
      Enum.reduce(lo_start..hi_end//step, 0, fn lo, acc ->
        rows = builder.(lo, lo + step)
        inserted = insert_batch(rows)
        if sleep > 0 and rows != [], do: Process.sleep(sleep)
        acc + inserted
      end)
    end
  end

  defp insert_batch([]), do: 0

  # Sub-batch so we never exceed Postgres's 65_535 bind-parameter cap: each row
  # binds 8 columns, so a full 10k id-chunk would be 80k params and blow up
  # (hit on prod 2026-06-09). @max_insert_rows × 8 = 32k params, safely under.
  defp insert_batch(rows) do
    rows
    |> Enum.chunk_every(@max_insert_rows)
    |> Enum.reduce(0, fn batch, acc ->
      {count, _} = Repo.insert_all("data_refreshes", batch, on_conflict: :nothing)
      acc + count
    end)
  end

  # table names here are this module's own literals (not user input)
  defp max_id(table) do
    %{rows: [[v]]} =
      Ecto.Adapters.SQL.query!(Repo.replica(), "SELECT COALESCE(MAX(id), 0) FROM #{table}", [])

    v
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp to_utc(nil), do: nil
  defp to_utc(%DateTime{} = dt), do: DateTime.truncate(dt, :second)

  defp to_utc(%NaiveDateTime{} = nd),
    do: nd |> DateTime.from_naive!("Etc/UTC") |> DateTime.truncate(:second)

  defp blank?(nil), do: true
  defp blank?(s) when is_binary(s), do: String.trim(s) == ""
  defp blank?(_), do: false
end

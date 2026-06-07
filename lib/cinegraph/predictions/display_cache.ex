defmodule Cinegraph.Predictions.DisplayCache do
  @moduledoc """
  The `/algorithms` display cache (#1084 P0b) — the single home for cache keys, TTLs, and busts.

  These pages are prebuilt-shaped: index cards and per-list rankings change **only** when a
  model is promoted/demoted/imported, when the catalog is reseeded, or as the underlying data
  drifts. The cache encodes exactly that:

    * **Keys carry model identity** — `{kind, source_key, model.id, model.weights_hash, limit}`
      for rankings; the index key embeds `board_version/0` (a hash of every active list's
      pointer), so any pointer flip self-invalidates even before the explicit bust fires.
    * **Explicit busts** — `MovieLists.set_active_prediction_model/3` (the sole pointer write
      path: covers promote, demote, and `ModelBundle.import`) and `Metrics.bust_catalog_cache/0`
      (catalog reseed) clear this cache.
    * **Two TTL regimes (#1084 A.1)** — cards: 15 min (cheap to rebuild; short TTL is the
      honesty bound for continuously-drifting inputs — `external_metrics` refreshes, membership
      and import changes, frontier movement). Rankings: 12 h, WARMER-OWNED — recomputes cost
      minutes per list on prod, so `Workers.AlgorithmsCacheWarmer` (boot + 6h cron + post-bust)
      is the refresh mechanism and the TTL is only a safety net. Freshness for rankings comes
      from the warmer cadence, not the TTL; explicit busts still apply.
    * **Canonical limit slicing** — rankings are computed and cached once at limit 48; smaller
      asks (show 24, compare 8) slice that one entry. Larger asks key separately.
    * **Single-flight** — a double-checked lock via `Cachex.transaction/3` (per-key sleeplock)
      guarantees exactly ONE recompute per key under concurrent misses. (Cachex 3.6's
      `fetch` courier has a dedup race — measured 2 executions from 6 concurrent misses — so
      we lock explicitly; the single-flight test pins the behavior.)
    * **Errors are never cached** — a `{:error, _}` from the underlying read-model passes
      through uncached (`:ignore`), so a transient failure can't pin a list to a broken state
      for 15 minutes.
  """

  import Ecto.Query

  alias Cinegraph.Predictions.Candidates
  alias Cinegraph.Repo
  alias Cinegraph.Scoring.Bus

  @cache :algorithms_cache
  # Cards are cheap to rebuild (~53 indexed queries) — short TTL keeps drift bounded.
  @cards_ttl :timer.minutes(15)
  # Rankings cost minutes-to-an-hour to recompute on prod (pools up to 258k movies) — they are
  # WARMER-OWNED (#1084 A.1): `Workers.AlgorithmsCacheWarmer` recomputes on boot, on a 6h cron,
  # and after every bust. The long TTL is a safety net, not the refresh mechanism; a 15-min TTL
  # here guaranteed perpetual cold (every recompute died with its visitor's socket).
  @rank_ttl :timer.hours(12)
  # Rankings are cached once at this limit and sliced for smaller asks, so the show page (24),
  # compare columns (8), and the warmer all share ONE cache entry per list.
  @canonical_limit 48

  @doc "Cached index cards. The caller supplies the build fun (kept in `AlgorithmsLive.Index`)."
  def index_cards(fun) when is_function(fun, 0) do
    fetch_any({:index_cards, board_version()}, fun, @cards_ttl)
  end

  @doc "Cached `Candidates.next_additions/2` keyed by the list's served-model identity."
  def next_additions(source_key, opts \\ []) do
    cached_rank(:next_additions, source_key, opts, fn cache_limit ->
      Candidates.next_additions(source_key, Keyword.put(opts, :limit, cache_limit))
    end)
  end

  @doc "Cached `Candidates.rank(…, mode: \"members\")` keyed by the served-model identity."
  def ranked_members(source_key, opts \\ []) do
    cached_rank(:ranked_members, source_key, opts, fn cache_limit ->
      Candidates.rank(
        source_key,
        opts |> Keyword.put(:mode, "members") |> Keyword.put(:limit, cache_limit)
      )
    end)
  end

  @doc """
  A hash of every active list's `{source_key, active_prediction_model_id}` — one cheap indexed
  query. Embedding it in the index key makes the cards self-invalidate on any pointer change.
  """
  def board_version do
    Repo.all(
      from l in "movie_lists",
        where: l.active == true,
        select: {l.source_key, l.active_prediction_model_id}
    )
    |> Enum.sort()
    |> :erlang.phash2()
  end

  @doc """
  Clear everything — promotion/demotion/import/catalog-reseed all route here — and enqueue the
  warmer so the rankings come back without a visitor paying the recompute.
  """
  def bust do
    Cachex.clear(@cache)
    Cinegraph.Workers.AlgorithmsCacheWarmer.enqueue()
    :ok
  end

  # ── internals ─────────────────────────────────────────────────────────────────────

  # No served model → the cheap error path; don't cache it (the model may appear any moment).
  # Asks ≤ @canonical_limit share one entry (computed at the canonical limit, sliced on read);
  # larger asks (show-more) get their own keyed entry.
  defp cached_rank(kind, source_key, opts, fun) do
    asked = Keyword.get(opts, :limit, @canonical_limit)

    case Bus.active_model(source_key) do
      nil ->
        fun.(asked)

      model ->
        cache_limit = max(asked, @canonical_limit)
        key = {kind, source_key, model.id, model.weights_hash, cache_limit}

        case fetch_ok(key, fn -> fun.(cache_limit) end) do
          {:ok, result} when asked < cache_limit ->
            {:ok, %{result | rows: Enum.take(result.rows, asked)}}

          other ->
            other
        end
    end
  end

  # Cache only {:ok, _} results; {:error, _} passes through uncached.
  defp fetch_ok(key, fun), do: fetch(key, fun, _commit_when = &match?({:ok, _}, &1), @rank_ttl)

  defp fetch_any(key, fun, ttl), do: fetch(key, fun, fn _ -> true end, ttl)

  # Double-checked lock: fast-path read, then a per-key transaction (sleeplock) so concurrent
  # misses serialize and exactly ONE caller computes; the rest read the committed value.
  defp fetch(key, fun, commit_when, ttl) do
    case Cachex.get(@cache, key) do
      {:ok, nil} -> locked_compute(key, fun, commit_when, ttl)
      {:ok, value} -> value
      _ -> fun.()
    end
  end

  defp locked_compute(key, fun, commit_when, ttl) do
    result =
      Cachex.transaction(@cache, [key], fn cache ->
        case Cachex.get(cache, key) do
          {:ok, nil} ->
            value = fun.()
            if commit_when.(value), do: Cachex.put(cache, key, value, ttl: ttl)
            value

          {:ok, value} ->
            value

          _ ->
            fun.()
        end
      end)

    case result do
      {:ok, value} -> value
      _ -> fun.()
    end
  end
end

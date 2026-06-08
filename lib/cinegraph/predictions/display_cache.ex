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
    * **TTL 15 minutes on every entry** — the named honesty bound for inputs that drift
      continuously and cannot be exact-keyed: `external_metrics` refreshes, list membership and
      import changes, frontier movement. The TTL bounds how stale those can render; it is not a
      substitute for the explicit busts above.
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
  @ttl :timer.minutes(15)

  @doc "Cached index cards. The caller supplies the build fun (kept in `AlgorithmsLive.Index`)."
  def index_cards(fun) when is_function(fun, 0) do
    fetch_any({:index_cards, board_version()}, fun)
  end

  @doc "Cached `Candidates.next_additions/2` keyed by the list's served-model identity."
  def next_additions(source_key, opts \\ []) do
    cached_rank(:next_additions, source_key, opts, fn ->
      Candidates.next_additions(source_key, opts)
    end)
  end

  @doc "Cached `Candidates.rank(…, mode: \"members\")` keyed by the served-model identity."
  def ranked_members(source_key, opts \\ []) do
    cached_rank(:ranked_members, source_key, opts, fn ->
      Candidates.rank(source_key, Keyword.put(opts, :mode, "members"))
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

  @doc "Clear everything — promotion/demotion/import/catalog-reseed all route here."
  def bust do
    Cachex.clear(@cache)
    :ok
  end

  # ── internals ─────────────────────────────────────────────────────────────────────

  # No served model → the cheap error path; don't cache it (the model may appear any moment).
  defp cached_rank(kind, source_key, opts, fun) do
    case Bus.active_model(source_key) do
      nil ->
        fun.()

      model ->
        fetch_ok(
          {kind, source_key, model.id, model.weights_hash, Keyword.get(opts, :limit, 48)},
          fun
        )
    end
  end

  # Cache only {:ok, _} results; {:error, _} passes through uncached.
  defp fetch_ok(key, fun), do: fetch(key, fun, _commit_when = &match?({:ok, _}, &1))

  defp fetch_any(key, fun), do: fetch(key, fun, fn _ -> true end)

  # Double-checked lock: fast-path read, then a per-key transaction (sleeplock) so concurrent
  # misses serialize and exactly ONE caller computes; the rest read the committed value.
  defp fetch(key, fun, commit_when) do
    case Cachex.get(@cache, key) do
      {:ok, nil} -> locked_compute(key, fun, commit_when)
      {:ok, value} -> value
      _ -> fun.()
    end
  end

  defp locked_compute(key, fun, commit_when) do
    result =
      Cachex.transaction(@cache, [key], fn cache ->
        case Cachex.get(cache, key) do
          {:ok, nil} ->
            value = fun.()
            if commit_when.(value), do: Cachex.put(cache, key, value, ttl: @ttl)
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

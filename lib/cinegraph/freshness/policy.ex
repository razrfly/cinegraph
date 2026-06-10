defmodule Cinegraph.Freshness.Policy do
  @moduledoc """
  Per-`(entity_type, source)` staleness strategy registry (#1010 §4).

  Staleness is a **pluggable strategy**, not one global age matrix. A new
  API/entity = one `@registry` entry, picked up automatically by `touch`, the
  report, and (later) the floor/read-through. **Every source is registered from
  day one** even where the refresh *behavior* is deferred — tracking is universal;
  only behavior differs (age-tiered vs fixed-cadence vs frozen).

  This module is **pure** (no DB): the caller supplies the entity's `base_date`
  (movie `release_date`, person latest-credit date), so the registry stays
  unit-testable without fixtures.

  Age tiers (entity age relative to the fetch anchor):

    * movie (by `release_date`): new `<90d` · recent `<2y` · catalog `<20y` · old
    * person (by `latest_credit`): new `<1y` · recent `<5y` · catalog `<20y` · old

  TTLs differ by volatility (availability churns, ratings settle, old metadata is
  static); tuned later in #1010 Phase 6. `:empty` responses wait `@empty_multiplier`
  times longer (subsumes the OMDb 90-day `fetch_attempt` cooldown).
  """
  require Logger

  @registry %{
    # 🟢 CORE
    "movie" => %{
      "tmdb_details" =>
        {:age_tiered, :release_date, %{new: 7, recent: 30, catalog: 180, old: 365}},
      "omdb" => {:age_tiered, :release_date, %{new: 7, recent: 30, catalog: 90, old: 365}},
      "watch_providers" =>
        {:age_tiered, :release_date, %{new: 3, recent: 7, catalog: 30, old: 90}},
      # imdb_id rides the tmdb_details fetch (same TMDb top-level field) — identical
      # TTL so the two couple and are serviced together. It never independently drives
      # a refresh; this entry only lets `touch/5` resolve a TTL (#1109).
      "imdb_id" => {:age_tiered, :release_date, %{new: 7, recent: 30, catalog: 180, old: 365}}
    },
    "person" => %{
      "tmdb_person" =>
        {:age_tiered, :latest_credit, %{new: 30, recent: 90, catalog: 180, old: 365}}
    },
    # 🔵 EXPANSION (#1090 Phase 5) — intentionally flat monthly, not age-tiered
    "list" => %{"imdb_list" => {:fixed_cadence, 30}},
    "festival_event" => %{"year_discovery" => {:fixed_cadence, 30}}
  }

  @empty_multiplier 3
  @default_ttl_days 30
  @max_error_attempts 8
  @day_seconds 86_400

  @doc "The full strategy registry (for the report's source inventory + docs)."
  def registry, do: @registry

  @doc "Errors escalate to `:ineligible` after this many attempts (#1010 §6)."
  def max_error_attempts, do: @max_error_attempts

  @doc """
  Compute `stale_after` for a successful/empty/pending refresh of `source`.

  `anchor` is the fetch time (≈ now). `base_date` is the entity's age key (a
  `Date` or `DateTime`, or nil → treated as `:catalog`). Returns a `DateTime`, or
  `nil` for frozen sources. `:error`/`:ineligible` are handled by `Freshness.touch`
  (backoff / never-due), not here.
  """
  def stale_after(entity_type, source, base_date, anchor, opts \\ []) do
    status = Keyword.get(opts, :status, :ok)
    metadata = Keyword.get(opts, :metadata, %{})

    case strategy(entity_type, source) do
      {:age_tiered, base_kind, ttls} ->
        ttl = Map.fetch!(ttls, tier(base_kind, base_date, anchor))
        ttl = if status == :empty, do: ttl * @empty_multiplier, else: ttl
        add_days(anchor, ttl)

      {:fixed_cadence, days} ->
        add_days(anchor, ttl_override(metadata, days))

      {:frozen} ->
        nil

      nil ->
        Logger.warning(
          "Freshness.Policy: no strategy for #{entity_type}/#{source}; defaulting to #{@default_ttl_days}d"
        )

        add_days(anchor, @default_ttl_days)
    end
  end

  @doc "Error backoff in seconds: 1h → 2h → 4h … capped at 7d (`attempt` is 1-based)."
  def backoff(attempt) when is_integer(attempt) and attempt > 0 do
    seconds = 3600 * Integer.pow(2, min(attempt - 1, 20))
    min(seconds, 7 * @day_seconds)
  end

  def backoff(_), do: 3600

  defp strategy(entity_type, source) do
    @registry |> Map.get(entity_type, %{}) |> Map.get(source)
  end

  # entity age (relative to the fetch anchor) → tier bucket
  defp tier(_base_kind, nil, _anchor), do: :catalog

  defp tier(base_kind, %Date{} = base_date, anchor) do
    classify(base_kind, Date.diff(DateTime.to_date(anchor), base_date))
  end

  defp tier(base_kind, %DateTime{} = base_dt, anchor) do
    classify(base_kind, div(DateTime.diff(anchor, base_dt, :second), @day_seconds))
  end

  defp classify(:release_date, d) when d < 90, do: :new
  defp classify(:release_date, d) when d < 730, do: :recent
  defp classify(:release_date, d) when d < 7300, do: :catalog
  defp classify(:release_date, _), do: :old

  defp classify(:latest_credit, d) when d < 365, do: :new
  defp classify(:latest_credit, d) when d < 1825, do: :recent
  defp classify(:latest_credit, d) when d < 7300, do: :catalog
  defp classify(:latest_credit, _), do: :old

  defp ttl_override(%{"ttl_override_days" => d}, _default) when is_integer(d) and d > 0, do: d
  defp ttl_override(_metadata, default), do: default

  defp add_days(anchor, days), do: DateTime.add(anchor, days * @day_seconds, :second)
end

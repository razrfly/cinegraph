defmodule Cinegraph.Freshness.Report do
  @moduledoc """
  Per-source rollup over `data_refreshes` (#1096 Phase B). The single query that
  answers "how fresh is everything?" — one row per source with
  `tracked / fresh / stale / never / ineligible / errors / oldest_fetch`.

  Every source in the `Policy` registry appears even with zero ledger rows, so a
  source that's registered-but-never-backfilled is visible (the §4b "tracked:
  never fetched" goal). Powers `mix cinegraph.freshness.report`.
  """
  import Ecto.Query

  alias Cinegraph.Freshness.{DataRefresh, Policy}
  alias Cinegraph.Repo

  @doc "Returns `%{generated_at: DateTime, sources: [row]}`."
  def report do
    now = DateTime.utc_now()
    counts = Map.new(source_counts(now), &{&1.source, &1})

    sources =
      registry_sources()
      |> Enum.map(fn {entity_type, source} ->
        base = Map.get(counts, source, empty_row(source))
        Map.put(base, :entity_type, entity_type)
      end)

    %{generated_at: now, sources: sources}
  end

  # one grouped aggregate over the whole ledger
  defp source_counts(now) do
    from(r in DataRefresh,
      group_by: r.source,
      select: %{
        source: r.source,
        tracked: count(r.id),
        # status partition: fresh + stale split the fetched rows; the rest are
        # their own buckets (pending = never attempted, plus error / ineligible).
        # A nil stale_after on an ok/empty row means a `:frozen` source (never
        # expires) — count it as perpetually fresh so the invariant holds:
        # tracked = fresh + stale + never + ineligible + errors.
        never: filter(count(r.id), r.status == "pending"),
        ineligible: filter(count(r.id), r.status == "ineligible"),
        errors: filter(count(r.id), r.status == "error"),
        stale:
          filter(
            count(r.id),
            r.status in ["ok", "empty"] and not is_nil(r.stale_after) and r.stale_after < ^now
          ),
        fresh:
          filter(
            count(r.id),
            r.status in ["ok", "empty"] and (is_nil(r.stale_after) or r.stale_after >= ^now)
          ),
        oldest_fetch: min(r.fetched_at)
      }
    )
    |> Repo.replica().all()
  end

  defp empty_row(source) do
    %{
      source: source,
      tracked: 0,
      never: 0,
      ineligible: 0,
      errors: 0,
      stale: 0,
      fresh: 0,
      oldest_fetch: nil
    }
  end

  # flatten the registry into a stable [{entity_type, source}] inventory
  defp registry_sources do
    for {entity_type, sources} <- Policy.registry(),
        {source, _strategy} <- sources do
      {entity_type, source}
    end
    |> Enum.sort()
  end
end

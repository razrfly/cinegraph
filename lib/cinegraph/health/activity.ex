defmodule Cinegraph.Health.Activity do
  @moduledoc """
  Today's activity counters — how many movies/people/ceremonies were
  added, how many OMDb fetches happened, how many Oban jobs completed
  vs failed.

  Single source for `mix cinegraph.activity` and the activity strip on
  `/admin/health` (#723).
  """

  import Ecto.Query
  alias Cinegraph.Health.ObanReader
  alias Cinegraph.Repo

  @cache_name :health_cache
  @cache_ttl :timer.minutes(1)

  @doc """
  Counters for the given UTC date (defaults to today).

  ## Shape

      %{
        date: ~D[2026-04-25],
        movies_added: 142,
        people_added: 17,
        ceremonies_updated: 3,
        omdb_fetches: 89,
        jobs_completed: 18_402,
        jobs_failed: 7
      }
  """
  def for_date(date \\ Date.utc_today(), opts \\ []) do
    if Keyword.get(opts, :bypass_cache, false) do
      compute(date)
    else
      case Cachex.fetch(@cache_name, {:activity, date}, fn ->
             {:commit, compute(date), ttl: @cache_ttl}
           end) do
        {:ok, value} -> value
        {:commit, value} -> value
        _ -> compute(date)
      end
    end
  end

  @doc """
  Convenience for today (UTC).
  """
  def today(opts \\ []), do: for_date(Date.utc_today(), opts)

  @doc """
  Counters per day for the last `days` UTC dates (most recent first).
  Used for sparklines.

  Accepts `:bypass_cache` (forwarded to each per-date computation) so the
  LiveView's "Refresh now" can rebuild sparklines without serving stale
  cached data.
  """
  def recent(days \\ 7, opts \\ []) when is_integer(days) and days > 0 do
    today = Date.utc_today()

    Enum.map(0..(days - 1), fn offset ->
      date = Date.add(today, -offset)
      for_date(date, opts)
    end)
  end

  defp compute(%Date{} = date) do
    {:ok, day_start, _} = "#{Date.to_iso8601(date)}T00:00:00Z" |> DateTime.from_iso8601()
    day_end = DateTime.add(day_start, 86_400, :second)

    %{
      date: date,
      movies_added: count_movies_inserted(day_start, day_end),
      people_added: count_people_inserted(day_start, day_end),
      ceremonies_updated: count_ceremonies_updated(day_start, day_end),
      omdb_fetches: count_omdb_fetches_in(day_start, day_end),
      jobs_completed: ObanReader.count_completed_in(day_start, day_end),
      jobs_failed: ObanReader.count_failed_in(day_start, day_end)
    }
  end

  # Ecto queries (parameterized, no string interpolation of values or sources).
  # Replica failures raise via Repo.replica().one and are caught by the
  # LiveView's safe/1 wrapper.
  defp count_movies_inserted(start_dt, end_dt) do
    from(m in "movies",
      where: m.inserted_at >= ^start_dt and m.inserted_at < ^end_dt,
      select: count(m.id)
    )
    |> Repo.replica().one()
    |> Kernel.||(0)
  end

  defp count_people_inserted(start_dt, end_dt) do
    from(p in "people",
      where: p.inserted_at >= ^start_dt and p.inserted_at < ^end_dt,
      select: count(p.id)
    )
    |> Repo.replica().one()
    |> Kernel.||(0)
  end

  defp count_ceremonies_updated(start_dt, end_dt) do
    from(c in "festival_ceremonies",
      where: c.updated_at >= ^start_dt and c.updated_at < ^end_dt,
      select: count(c.id)
    )
    |> Repo.replica().one()
    |> Kernel.||(0)
  end

  defp count_omdb_fetches_in(start_dt, end_dt) do
    from(em in "external_metrics",
      where: em.source == "omdb" and em.fetched_at >= ^start_dt and em.fetched_at < ^end_dt,
      select: count(em.id)
    )
    |> Repo.replica().one()
    |> Kernel.||(0)
  end
end

defmodule Cinegraph.Health.Completeness do
  @moduledoc """
  Catalog completeness snapshot — coverage percentages and total counts
  per domain. Persisted daily into `completeness_log` so the dashboard
  in #723 can chart trend.

  Backs `mix cinegraph.completeness` and (after #723 ships) the
  30-day chart on `/admin/health`.
  """

  import Ecto.Query
  alias Cinegraph.Health.CompletenessLog
  alias Cinegraph.Repo

  @doc """
  Computes a snapshot **without** persisting.

  Returns a map suitable for serialization to the `completeness_log.payload`
  JSONB column or `Jason.encode!`.

  ## Shape

      %{
        generated_at: ~U[...],
        movies: %{total: 1_140_646, with_omdb: 985_400, with_omdb_pct: 86.4,
                   with_imdb_id: 1_123_400, with_imdb_id_pct: 98.5},
        people: %{total: 671_186, with_profile: 658_705, with_profile_pct: 98.1,
                   with_biography: 540_000, with_biography_pct: 80.4,
                   with_known_for: 670_000, with_known_for_pct: 99.8},
        festivals: %{ceremonies: 480, nominations: 18_400, with_movie_pct: 99.9},
        overall_completeness_pct: 90.5
      }
  """
  def run do
    movies = movies_completeness()
    people = people_completeness()
    festivals = festivals_completeness()

    overall =
      [
        movies.with_omdb_pct,
        movies.with_imdb_id_pct,
        people.with_profile_pct,
        people.with_biography_pct,
        people.with_known_for_pct,
        festivals.with_movie_pct
      ]
      |> avg()

    %{
      generated_at: DateTime.utc_now(),
      movies: movies,
      people: people,
      festivals: festivals,
      overall_completeness_pct: overall
    }
  end

  @doc """
  Computes a snapshot and persists it (upsert by `captured_on` UTC date).
  """
  def run_and_persist do
    persist(run())
  end

  @doc """
  Persists a pre-computed snapshot (returned by `run/0`). Lets callers that
  need both the snapshot and the persisted log (e.g. `mix
  cinegraph.completeness --write`) avoid recomputing.
  """
  def persist(snapshot) do
    today = Date.utc_today()
    payload = serializable(snapshot)

    %CompletenessLog{}
    |> CompletenessLog.changeset(%{captured_on: today, payload: payload})
    |> Repo.insert(
      on_conflict: {:replace, [:payload]},
      conflict_target: :captured_on,
      returning: true
    )
  end

  @doc """
  The most recent `days` entries from `completeness_log`, oldest first
  (for plotting).

  Accepts `:bypass_cache` for symmetry with other Health surfaces; this
  function reads directly from `completeness_log` and does not cache, so
  the option is currently a no-op kept to make `Refresh now` callers
  forward consistently.
  """
  def history(days \\ 30, _opts \\ []) do
    since = Date.add(Date.utc_today(), -(days - 1))

    from(c in CompletenessLog,
      where: c.captured_on >= ^since,
      order_by: [asc: c.captured_on],
      select: %{captured_on: c.captured_on, payload: c.payload}
    )
    |> Repo.replica().all()
  end

  defp movies_completeness do
    %{total: total, with_omdb: with_omdb, with_imdb_id: with_imdb} =
      from(m in "movies",
        select: %{
          total: count(m.id),
          with_omdb: filter(count(m.id), not is_nil(m.omdb_data)),
          with_imdb_id: filter(count(m.id), not is_nil(m.imdb_id) and m.imdb_id != "")
        }
      )
      |> Repo.replica().one()

    %{
      total: total,
      with_omdb: with_omdb,
      with_omdb_pct: pct(with_omdb, total),
      with_imdb_id: with_imdb,
      with_imdb_id_pct: pct(with_imdb, total)
    }
  end

  defp people_completeness do
    %{
      total: total,
      with_profile: with_profile,
      with_biography: with_bio,
      with_known_for: with_known
    } =
      from(p in "people",
        select: %{
          total: count(p.id),
          with_profile: filter(count(p.id), not is_nil(p.profile_path)),
          with_biography: filter(count(p.id), not is_nil(p.biography) and p.biography != ""),
          with_known_for: filter(count(p.id), not is_nil(p.known_for_department))
        }
      )
      |> Repo.replica().one()

    %{
      total: total,
      with_profile: with_profile,
      with_profile_pct: pct(with_profile, total),
      with_biography: with_bio,
      with_biography_pct: pct(with_bio, total),
      with_known_for: with_known,
      with_known_for_pct: pct(with_known, total)
    }
  end

  defp festivals_completeness do
    ceremonies =
      Repo.replica().one(from(c in "festival_ceremonies", select: count(c.id))) || 0

    %{nominations: nominations, with_movie: with_movie} =
      from(n in "festival_nominations",
        select: %{
          nominations: count(n.id),
          with_movie: filter(count(n.id), not is_nil(n.movie_id))
        }
      )
      |> Repo.replica().one()

    %{
      ceremonies: ceremonies,
      nominations: nominations,
      with_movie_pct: pct(with_movie, nominations)
    }
  end

  defp pct(_count, 0), do: 0.0

  defp pct(count, total) when is_integer(count) and is_integer(total) do
    Float.round(count / total * 100, 2)
  end

  defp avg(list) when is_list(list) and length(list) > 0,
    do: Float.round(Enum.sum(list) / length(list), 2)

  # Convert atom-keyed map with DateTime/Date into JSON-safe form for storage
  defp serializable(snapshot) do
    snapshot
    |> Map.put(:generated_at, DateTime.to_iso8601(snapshot.generated_at))
    |> stringify_keys()
  end

  defp stringify_keys(map) when is_map(map) and not is_struct(map) do
    Map.new(map, fn {k, v} ->
      {to_string(k), stringify_keys(v)}
    end)
  end

  defp stringify_keys(%Date{} = d), do: Date.to_iso8601(d)
  defp stringify_keys(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(value), do: value
end

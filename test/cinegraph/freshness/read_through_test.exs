defmodule Cinegraph.Freshness.ReadThroughTest do
  @moduledoc "#1108 §10b — demand-driven read-through refresh."
  use Cinegraph.DataCase, async: false

  import Ecto.Query

  alias Cinegraph.Freshness
  alias Cinegraph.Freshness.{DataRefresh, ReadThrough}
  alias Cinegraph.Movies.{Movie, Person}
  alias Cinegraph.Repo
  alias Cinegraph.Workers.{OMDbEnrichmentWorker, PersonTmdbRefreshWorker, TMDbMovieRefreshWorker}

  setup do
    Cachex.clear(:health_cache)
    prev = Application.get_env(:cinegraph, :read_through_enabled)
    Application.put_env(:cinegraph, :read_through_enabled, true)
    on_exit(fn -> Application.put_env(:cinegraph, :read_through_enabled, prev) end)
    :ok
  end

  defp movie! do
    %Movie{}
    |> Movie.changeset(%{tmdb_id: System.unique_integer([:positive]), title: "M"})
    |> Repo.insert!()
  end

  defp person! do
    %Person{}
    |> Person.changeset(%{tmdb_id: System.unique_integer([:positive]), name: "P"})
    |> Repo.insert!()
  end

  # mark a source FRESH (stale_after far future) so it's not stale
  defp fresh!(type, id, source) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    %DataRefresh{}
    |> DataRefresh.changeset(%{
      entity_type: to_string(type),
      entity_id: id,
      source: source,
      status: "ok",
      fetched_at: now,
      stale_after: DateTime.add(now, 365 * 86_400, :second)
    })
    |> Repo.insert!()
  end

  defp enqueued(worker), do: Repo.all(from(j in Oban.Job, where: j.worker == ^inspect(worker)))

  test "movie with no ledger rows → stale → enqueues one TMDbMovieRefreshWorker + one OMDb" do
    m = movie!()
    assert {:enqueued, tags} = ReadThrough.refresh_if_stale(%{type: :movie, id: m.id})
    assert :tmdb_movie in tags and :omdb in tags
    assert length(enqueued(TMDbMovieRefreshWorker)) == 1
    assert length(enqueued(OMDbEnrichmentWorker)) == 1
    # ≤3 invariant
    assert length(tags) <= 3
  end

  test "all sources fresh → :fresh, no enqueues" do
    m = movie!()
    for src <- ~w(tmdb_details watch_providers omdb imdb_id), do: fresh!(:movie, m.id, src)

    assert :fresh = ReadThrough.refresh_if_stale(%{type: :movie, id: m.id})
    assert enqueued(TMDbMovieRefreshWorker) == []
    assert enqueued(OMDbEnrichmentWorker) == []
  end

  test "spend-guard off → :skipped, nothing enqueued, but canary still stamped" do
    Application.put_env(:cinegraph, :read_through_enabled, false)
    m = movie!()
    # a tracked row (other sources remain nil→stale, so the result is :skipped)
    fresh!(:movie, m.id, "tmdb_details")

    assert :skipped = ReadThrough.refresh_if_stale(%{type: :movie, id: m.id})
    assert enqueued(TMDbMovieRefreshWorker) == []

    row = Repo.get_by(DataRefresh, entity_type: "movie", entity_id: m.id, source: "tmdb_details")
    refute is_nil(row.last_checked_at)
  end

  test "person stale → one PersonTmdbRefreshWorker" do
    p = person!()
    assert {:enqueued, [:tmdb_person]} = ReadThrough.refresh_if_stale(%{type: :person, id: p.id})
    assert length(enqueued(PersonTmdbRefreshWorker)) == 1
  end

  test "Oban unique dedups two consecutive calls into one job" do
    m = movie!()
    ReadThrough.refresh_if_stale(%{type: :movie, id: m.id})
    ReadThrough.refresh_if_stale(%{type: :movie, id: m.id})
    assert length(enqueued(TMDbMovieRefreshWorker)) == 1
  end

  test "stamp_checked updates existing rows only — never inserts for an untracked entity" do
    m = movie!()
    Application.put_env(:cinegraph, :read_through_enabled, false)

    ReadThrough.refresh_if_stale(%{type: :movie, id: m.id})

    count =
      Repo.one(
        from(r in DataRefresh,
          where: r.entity_type == "movie" and r.entity_id == ^m.id,
          select: count(r.id)
        )
      )

    assert count == 0
  end

  test "stamp_checked sets last_checked_at on a tracked row (the canary)" do
    m = movie!()
    fresh!(:movie, m.id, "tmdb_details")

    ReadThrough.refresh_if_stale(%{type: :movie, id: m.id})

    row = Repo.get_by(DataRefresh, entity_type: "movie", entity_id: m.id, source: "tmdb_details")
    refute is_nil(row.last_checked_at)
  end

  test "stale_sources: nil→stale, ineligible→fresh, future→fresh, past→stale" do
    m = movie!()
    fresh!(:movie, m.id, "tmdb_details")
    # ineligible
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    %DataRefresh{}
    |> DataRefresh.changeset(%{
      entity_type: "movie",
      entity_id: m.id,
      source: "omdb",
      status: "ineligible"
    })
    |> Repo.insert!()

    # past-due watch_providers
    %DataRefresh{}
    |> DataRefresh.changeset(%{
      entity_type: "movie",
      entity_id: m.id,
      source: "watch_providers",
      status: "ok",
      fetched_at: DateTime.add(now, -10 * 86_400, :second),
      stale_after: DateTime.add(now, -86_400, :second)
    })
    |> Repo.insert!()

    stale = Freshness.stale_sources(:movie, m.id)
    refute "tmdb_details" in stale
    refute "omdb" in stale
    assert "watch_providers" in stale
    # imdb_id has no row → stale
    assert "imdb_id" in stale
  end
end

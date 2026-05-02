defmodule Cinegraph.Health.Drift.AvailabilityTest do
  use Cinegraph.DataCase, async: false

  alias Cinegraph.Health.Drift.Availability
  alias Cinegraph.Movies.{Movie, MovieAvailabilityRefresh}
  alias Cinegraph.Repo

  setup do
    Cachex.clear(:health_cache)
    :ok
  end

  test "all/1 returns the four availability checks" do
    checks = Availability.all()

    assert Enum.map(checks, & &1.check) |> Enum.sort() ==
             [
               :availability_fetch_errors,
               :availability_missing,
               :availability_provider_catalog_stale,
               :availability_stale
             ]
  end

  test "availability_missing reports full movies without refresh rows" do
    movie = insert_movie!()

    result = Availability.availability_missing()

    assert result.domain == :availability
    assert result.check == :availability_missing
    assert result.affected_count == 1
    assert [%{id: id}] = result.examples
    assert id == movie.id
  end

  test "availability_fetch_errors reports error refresh rows" do
    movie = insert_movie!()
    insert_refresh!(movie, "error", ~U[2026-06-01 00:00:00Z], "boom")

    result = Availability.availability_fetch_errors()

    assert result.affected_count == 1
    assert [%{id: id, error_reason: "boom"}] = result.examples
    assert id == movie.id
  end

  defp insert_movie! do
    %Movie{}
    |> Movie.changeset(%{
      tmdb_id: System.unique_integer([:positive]),
      title: "Availability Drift Movie",
      original_title: "Availability Drift Movie",
      import_status: "full"
    })
    |> Repo.insert!()
  end

  defp insert_refresh!(movie, status, stale_after, error_reason) do
    %MovieAvailabilityRefresh{}
    |> MovieAvailabilityRefresh.changeset(%{
      movie_id: movie.id,
      region: "US",
      source: "tmdb",
      status: status,
      error_reason: error_reason,
      fetched_at: DateTime.add(stale_after, -30 * 86_400, :second),
      stale_after: stale_after
    })
    |> Repo.insert!()
  end
end

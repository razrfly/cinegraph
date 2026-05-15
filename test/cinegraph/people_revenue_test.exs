defmodule Cinegraph.PeopleRevenueTest do
  use Cinegraph.DataCase, async: true

  alias Cinegraph.People
  alias Cinegraph.Movies.{ExternalMetric, Movie}

  describe "revenue_map_for_movie_ids/1 (#913 PR A pt 2)" do
    test "sums revenue_worldwide rows from external_metrics into a movie_id => value map" do
      movie_a = insert_movie!()
      movie_b = insert_movie!()

      now = DateTime.utc_now() |> DateTime.truncate(:second)
      now_naive = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

      Repo.insert_all(ExternalMetric, [
        %{
          movie_id: movie_a.id,
          source: "tmdb",
          metric_type: "revenue_worldwide",
          value: 100_000_000.0,
          fetched_at: now,
          inserted_at: now_naive,
          updated_at: now_naive
        },
        %{
          movie_id: movie_b.id,
          source: "tmdb",
          metric_type: "revenue_worldwide",
          value: 250_000_000.0,
          fetched_at: now,
          inserted_at: now_naive,
          updated_at: now_naive
        },
        # Different metric_type — must be ignored
        %{
          movie_id: movie_a.id,
          source: "tmdb",
          metric_type: "budget",
          value: 50_000_000.0,
          fetched_at: now,
          inserted_at: now_naive,
          updated_at: now_naive
        },
        # Different source — must be ignored
        %{
          movie_id: movie_a.id,
          source: "omdb",
          metric_type: "revenue_worldwide",
          value: 999.0,
          fetched_at: now,
          inserted_at: now_naive,
          updated_at: now_naive
        }
      ])

      result = People.revenue_map_for_movie_ids([movie_a.id, movie_b.id])

      assert result[movie_a.id] == 100_000_000
      assert result[movie_b.id] == 250_000_000
    end

    test "returns %{} for empty input" do
      assert People.revenue_map_for_movie_ids([]) == %{}
    end

    test "returns %{} when no matching rows exist" do
      movie = insert_movie!()
      assert People.revenue_map_for_movie_ids([movie.id]) == %{}
    end

    test "omits movies with no revenue_worldwide row" do
      movie_a = insert_movie!()
      movie_b = insert_movie!()

      now = DateTime.utc_now() |> DateTime.truncate(:second)
      now_naive = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

      Repo.insert_all(ExternalMetric, [
        %{
          movie_id: movie_a.id,
          source: "tmdb",
          metric_type: "revenue_worldwide",
          value: 42_000_000.0,
          fetched_at: now,
          inserted_at: now_naive,
          updated_at: now_naive
        }
      ])

      result = People.revenue_map_for_movie_ids([movie_a.id, movie_b.id])

      assert result[movie_a.id] == 42_000_000
      refute Map.has_key?(result, movie_b.id)
    end

    test "deduplicates the input id list and ignores nils" do
      movie = insert_movie!()

      now = DateTime.utc_now() |> DateTime.truncate(:second)
      now_naive = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

      Repo.insert_all(ExternalMetric, [
        %{
          movie_id: movie.id,
          source: "tmdb",
          metric_type: "revenue_worldwide",
          value: 10_000_000.0,
          fetched_at: now,
          inserted_at: now_naive,
          updated_at: now_naive
        }
      ])

      result = People.revenue_map_for_movie_ids([movie.id, nil, movie.id])
      assert result[movie.id] == 10_000_000
      assert map_size(result) == 1
    end

    # NOTE: tests for "pick the latest fetched_at when duplicate
    # (movie_id, source, metric_type) rows exist" were removed in #923 —
    # the unique index added in migration 20250811132415 makes that state
    # unreachable in a sandbox transaction. The DISTINCT ON code path in
    # revenue_map_for_movie_ids/1 still matters for pre-2025-08-11 legacy
    # rows in prod (tracked in #916), but the regression is exercised by
    # the production data, not a unit test.
  end

  defp insert_movie!(attrs \\ %{}) do
    base = %{
      tmdb_id: System.unique_integer([:positive]),
      title: "Test Movie #{System.unique_integer([:positive])}"
    }

    {:ok, movie} =
      %Movie{}
      |> Movie.changeset(Map.merge(base, attrs))
      |> Repo.insert()

    movie
  end

end

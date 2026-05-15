defmodule Cinegraph.PeopleRevenueTest do
  use Cinegraph.DataCase, async: true

  alias Cinegraph.People
  alias Cinegraph.Movies.{Credit, ExternalMetric, Movie, Person}

  describe "revenue_map_for_movie_ids/1 (#913 PR A pt 2)" do
    test "sums revenue_worldwide rows from external_metrics into a movie_id => value map" do
      movie_a = insert_movie!()
      movie_b = insert_movie!()

      now = DateTime.utc_now() |> DateTime.truncate(:second)

      Repo.insert_all(ExternalMetric, [
        %{
          movie_id: movie_a.id,
          source: "tmdb",
          metric_type: "revenue_worldwide",
          value: 100_000_000.0,
          fetched_at: now,
          inserted_at: now,
          updated_at: now
        },
        %{
          movie_id: movie_b.id,
          source: "tmdb",
          metric_type: "revenue_worldwide",
          value: 250_000_000.0,
          fetched_at: now,
          inserted_at: now,
          updated_at: now
        },
        # Different metric_type — must be ignored
        %{
          movie_id: movie_a.id,
          source: "tmdb",
          metric_type: "budget",
          value: 50_000_000.0,
          fetched_at: now,
          inserted_at: now,
          updated_at: now
        },
        # Different source — must be ignored
        %{
          movie_id: movie_a.id,
          source: "omdb",
          metric_type: "revenue_worldwide",
          value: 999.0,
          fetched_at: now,
          inserted_at: now,
          updated_at: now
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

      Repo.insert_all(ExternalMetric, [
        %{
          movie_id: movie_a.id,
          source: "tmdb",
          metric_type: "revenue_worldwide",
          value: 42_000_000.0,
          fetched_at: now,
          inserted_at: now,
          updated_at: now
        }
      ])

      result = People.revenue_map_for_movie_ids([movie_a.id, movie_b.id])

      assert result[movie_a.id] == 42_000_000
      refute Map.has_key?(result, movie_b.id)
    end

    test "deduplicates the input id list and ignores nils" do
      movie = insert_movie!()

      now = DateTime.utc_now() |> DateTime.truncate(:second)

      Repo.insert_all(ExternalMetric, [
        %{
          movie_id: movie.id,
          source: "tmdb",
          metric_type: "revenue_worldwide",
          value: 10_000_000.0,
          fetched_at: now,
          inserted_at: now,
          updated_at: now
        }
      ])

      result = People.revenue_map_for_movie_ids([movie.id, nil, movie.id])
      assert result[movie.id] == 10_000_000
      assert map_size(result) == 1
    end

    test "picks the latest fetched_at when multiple revenue_worldwide rows exist for a movie" do
      # Regression guard for the Greptile finding on PR 919 — older bare
      # `sum(em.value)` double-counted re-fetched movies. The DISTINCT ON path
      # should keep only the newest row per movie.
      movie = insert_movie!()

      old = ~U[2024-01-01 00:00:00Z]
      new = ~U[2025-06-01 00:00:00Z]
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      Repo.insert_all(ExternalMetric, [
        %{
          movie_id: movie.id,
          source: "tmdb",
          metric_type: "revenue_worldwide",
          value: 100_000_000.0,
          fetched_at: old,
          inserted_at: now,
          updated_at: now
        },
        %{
          movie_id: movie.id,
          source: "tmdb",
          metric_type: "revenue_worldwide",
          value: 175_000_000.0,
          fetched_at: new,
          inserted_at: now,
          updated_at: now
        }
      ])

      result = People.revenue_map_for_movie_ids([movie.id])
      assert result[movie.id] == 175_000_000
    end
  end

  describe "get_career_stats/1 total_revenue (#913 PR A pt 2 — regression guard)" do
    test "does not double-count movies with multiple revenue_worldwide rows" do
      person = insert_person!()
      movie = insert_movie!()
      insert_cast_credit!(person, movie)

      old = ~U[2024-01-01 00:00:00Z]
      new = ~U[2025-06-01 00:00:00Z]
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      Repo.insert_all(ExternalMetric, [
        %{
          movie_id: movie.id,
          source: "tmdb",
          metric_type: "revenue_worldwide",
          value: 100_000_000.0,
          fetched_at: old,
          inserted_at: now,
          updated_at: now
        },
        %{
          movie_id: movie.id,
          source: "tmdb",
          metric_type: "revenue_worldwide",
          value: 175_000_000.0,
          fetched_at: new,
          inserted_at: now,
          updated_at: now
        }
      ])

      stats = People.get_career_stats(person.id)
      # Must be 175M (newest row), not 275M (sum of both rows).
      assert stats.total_revenue == 175_000_000
    end
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

  defp insert_person!(attrs \\ %{}) do
    base = %{
      tmdb_id: System.unique_integer([:positive]),
      name: "Test Person #{System.unique_integer([:positive])}"
    }

    {:ok, person} =
      %Person{}
      |> Person.changeset(Map.merge(base, attrs))
      |> Repo.insert()

    person
  end

  defp insert_cast_credit!(person, movie) do
    {:ok, credit} =
      %Credit{}
      |> Credit.changeset(%{
        person_id: person.id,
        movie_id: movie.id,
        credit_type: "cast",
        credit_id: "test-#{System.unique_integer([:positive])}"
      })
      |> Repo.insert()

    credit
  end
end

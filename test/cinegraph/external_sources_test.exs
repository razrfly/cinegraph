defmodule Cinegraph.ExternalSourcesTest do
  use Cinegraph.DataCase, async: true

  alias Cinegraph.ExternalSources
  alias Cinegraph.Movies.{ExternalMetric, Movie}

  describe "get_movie_ratings/1" do
    test "returns rows with :metric_type key (regression guard for #913 wiring bug)" do
      movie = insert_movie!()

      now = DateTime.utc_now() |> DateTime.truncate(:second)

      Repo.insert_all(ExternalMetric, [
        %{
          movie_id: movie.id,
          source: "imdb",
          metric_type: "rating_average",
          value: 8.5,
          metadata: %{"scale" => "1-10"},
          fetched_at: now,
          inserted_at: now,
          updated_at: now
        }
      ])

      [row] = ExternalSources.get_movie_ratings(movie.id)

      # The bug was: get_movie_ratings/1 returned `rating_type:` while consumers
      # match on `:metric_type`. Verify the key is `:metric_type` now.
      assert Map.has_key?(row, :metric_type)
      refute Map.has_key?(row, :rating_type)
      assert row.metric_type == "rating_average"
      assert row.value == 8.5
      assert row.source.name == "imdb"
    end

    test "filters to the rating-related metric_types whitelist" do
      movie = insert_movie!()
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      Repo.insert_all(ExternalMetric, [
        %{
          movie_id: movie.id,
          source: "imdb",
          metric_type: "rating_average",
          value: 8.0,
          fetched_at: now,
          inserted_at: now,
          updated_at: now
        },
        # text-typed metric — must NOT come back from get_movie_ratings/1
        %{
          movie_id: movie.id,
          source: "omdb",
          metric_type: "content_rating",
          text_value: "PG-13",
          fetched_at: now,
          inserted_at: now,
          updated_at: now
        }
      ])

      rows = ExternalSources.get_movie_ratings(movie.id)
      assert length(rows) == 1
      assert hd(rows).metric_type == "rating_average"
    end

    test "accepts a single source name as a binary filter" do
      movie = insert_movie!()
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      Repo.insert_all(ExternalMetric, [
        %{
          movie_id: movie.id,
          source: "imdb",
          metric_type: "rating_average",
          value: 8.0,
          fetched_at: now,
          inserted_at: now,
          updated_at: now
        },
        %{
          movie_id: movie.id,
          source: "tmdb",
          metric_type: "rating_average",
          value: 7.0,
          fetched_at: now,
          inserted_at: now,
          updated_at: now
        }
      ])

      [row] = ExternalSources.get_movie_ratings(movie.id, "imdb")
      assert row.source.name == "imdb"
      assert row.value == 8.0
    end
  end

  describe "get_movie_metrics/2" do
    test "filters to requested metric_types and includes text_value" do
      movie = insert_movie!()
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      Repo.insert_all(ExternalMetric, [
        %{
          movie_id: movie.id,
          source: "omdb",
          metric_type: "content_rating",
          text_value: "PG-13",
          fetched_at: now,
          inserted_at: now,
          updated_at: now
        },
        %{
          movie_id: movie.id,
          source: "omdb",
          metric_type: "awards_summary",
          text_value: "Won 2 Oscars",
          fetched_at: now,
          inserted_at: now,
          updated_at: now
        },
        # NOT requested — must be excluded
        %{
          movie_id: movie.id,
          source: "imdb",
          metric_type: "rating_average",
          value: 8.0,
          fetched_at: now,
          inserted_at: now,
          updated_at: now
        }
      ])

      rows = ExternalSources.get_movie_metrics(movie.id, ["content_rating", "awards_summary"])
      assert length(rows) == 2

      by_type = Map.new(rows, &{&1.metric_type, &1})
      assert by_type["content_rating"].text_value == "PG-13"
      assert by_type["content_rating"].source.name == "omdb"
      assert by_type["awards_summary"].text_value == "Won 2 Oscars"
    end

    test "returns [] when no matching rows exist" do
      movie = insert_movie!()
      assert ExternalSources.get_movie_metrics(movie.id, ["content_rating"]) == []
    end
  end

  describe "get_movie_metrics/3" do
    test "filters to requested source names" do
      movie = insert_movie!()
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      Repo.insert_all(ExternalMetric, [
        %{
          movie_id: movie.id,
          source: "omdb",
          metric_type: "content_rating",
          text_value: "PG-13",
          fetched_at: now,
          inserted_at: now,
          updated_at: now
        },
        %{
          movie_id: movie.id,
          source: "other_source",
          metric_type: "content_rating",
          text_value: "R",
          fetched_at: now,
          inserted_at: now,
          updated_at: now
        }
      ])

      [row] = ExternalSources.get_movie_metrics(movie.id, ["content_rating"], ["omdb"])
      assert row.text_value == "PG-13"
      assert row.source.name == "omdb"
    end

    test "accepts a single source name as a binary filter" do
      movie = insert_movie!()
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      Repo.insert_all(ExternalMetric, [
        %{
          movie_id: movie.id,
          source: "omdb",
          metric_type: "content_rating",
          text_value: "PG-13",
          fetched_at: now,
          inserted_at: now,
          updated_at: now
        },
        %{
          movie_id: movie.id,
          source: "other_source",
          metric_type: "content_rating",
          text_value: "R",
          fetched_at: now,
          inserted_at: now,
          updated_at: now
        }
      ])

      [row] = ExternalSources.get_movie_metrics(movie.id, ["content_rating"], "omdb")
      assert row.text_value == "PG-13"
      assert row.source.name == "omdb"
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
end

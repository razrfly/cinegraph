defmodule Cinegraph.Scoring.BusTest do
  @moduledoc "Layer-2 weighting bus: lens parity, data-point math, artifact reader (#1036 S3)."
  use Cinegraph.DataCase

  alias Cinegraph.Metrics.CatalogSeed
  alias Cinegraph.Movies.{Movie, MovieLists}
  alias Cinegraph.Predictions.{LensScoring, Model}
  alias Cinegraph.Repo
  alias Cinegraph.Scoring.Bus

  setup do
    CatalogSeed.seed!()
    :ok
  end

  defp plant_movie(attrs \\ %{}) do
    base = %{
      tmdb_id: System.unique_integer([:positive]),
      title: "M #{System.unique_integer([:positive])}"
    }

    %Movie{}
    |> Movie.changeset(Map.merge(base, attrs))
    |> Repo.insert!()
  end

  defp ext!(movie, source, metric_type, value) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.insert_all("external_metrics", [
      %{
        movie_id: movie.id,
        source: source,
        metric_type: metric_type,
        value: value,
        fetched_at: now,
        inserted_at: now,
        updated_at: now
      }
    ])
  end

  describe ":lens granularity" do
    test "reproduces LensScoring.total_score exactly" do
      movie = plant_movie(%{canonical_sources: %{}})
      ext!(movie, "imdb", "rating_average", 8.0)

      weights = LensScoring.get_default_weights()
      [%{prediction: p}] = LensScoring.batch_score_movies([movie], weights, "1001_movies")

      bus = Bus.score([movie], {:lens, weights, "1001_movies"})
      assert bus[movie.id] == p.total_score
    end

    test "a Model with lens granularity dispatches to the lens path" do
      movie = plant_movie(%{canonical_sources: %{}})
      ext!(movie, "imdb", "rating_average", 8.0)

      model = %Model{
        source_key: "1001_movies",
        feature_set: %{"granularity" => "lens", "features" => ~w(mob critics)},
        weights: %{"mob" => 0.5, "critics" => 0.5}
      }

      spec = Bus.score([movie], {:lens, %{"mob" => 0.5, "critics" => 0.5}, "1001_movies"})
      assert Bus.score([movie], model) == spec
    end
  end

  describe ":data_point granularity" do
    test "computes Σ wᵢ·normalizedᵢ over metric_codes (×100 scale)" do
      movie = plant_movie()
      # imdb_rating: linear 0..10 → 8.0 normalizes to 0.8
      ext!(movie, "imdb", "rating_average", 8.0)
      # metacritic: linear 0..100 → 50 normalizes to 0.5
      ext!(movie, "metacritic", "metascore", 50.0)

      weights = %{"imdb_rating" => 0.5, "metacritic_metascore" => 0.5}
      # 0.5*0.8 + 0.5*0.5 = 0.65 → ×100 = 65.0
      scores = Bus.score([movie], {:data_point, weights, "1001_movies"})
      assert_in_delta scores[movie.id], 65.0, 0.05
    end

    test "missing codes contribute 0 (imputed)" do
      movie = plant_movie()
      ext!(movie, "imdb", "rating_average", 10.0)

      weights = %{"imdb_rating" => 0.5, "tmdb_rating" => 0.5}
      # imdb 1.0 present, tmdb absent → 0.5*1.0 + 0.5*0 = 0.5 → 50.0
      scores = Bus.score([movie], {:data_point, weights, "1001_movies"})
      assert_in_delta scores[movie.id], 50.0, 0.05
    end
  end

  describe "active_model/1" do
    test "reads the artifact a list points at" do
      assert Bus.active_model("1001_movies") == nil

      {:ok, prereg} =
        Cinegraph.Predictions.PreRegistration.register(%{
          source_key: "1001_movies",
          expected_top_features: %{},
          expected_accuracy_range: %{},
          failure_threshold: "0.10"
        })

      {:ok, model} =
        %Model{}
        |> Model.changeset(%{
          source_key: "1001_movies",
          feature_set: %{"granularity" => "data_point", "features" => ["imdb_rating"]},
          weights: %{"imdb_rating" => 1.0},
          weights_hash: "h1",
          model_version: 1,
          prereg_id: prereg.id
        })
        |> Repo.insert()

      MovieLists.seed_default_lists()

      {:ok, _} =
        MovieLists.set_active_prediction_model("1001_movies", model.id, %{"imdb_rating" => 1.0})

      assert %Model{id: id} = Bus.active_model("1001_movies")
      assert id == model.id
    end
  end
end

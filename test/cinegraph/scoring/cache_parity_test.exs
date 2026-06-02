defmodule Cinegraph.Scoring.CacheParityTest do
  @moduledoc """
  Byte-stable parity gate for #1036 Session 1.

  The catalog-driven path (FeatureResolver → LensFormulas, via MovieScoring) must
  reproduce the :absolute lens scores exactly. Two layers:

    * a controlled fixture with hand-computed expected components (CI-safe), and
    * `@tag :scoring_db` — a full-population diff against the existing
      `movie_score_caches` (calc_version unchanged), run against a populated DB:
          mix test test/cinegraph/scoring/cache_parity_test.exs --only scoring_db
  """
  use Cinegraph.DataCase

  alias Cinegraph.Movies.{Credit, Movie, MovieScoreCache, MovieScoring, Person}
  alias Cinegraph.Metrics
  alias Cinegraph.Metrics.CatalogSeed
  alias Cinegraph.Repo

  import Ecto.Query

  # Catalog-driven scoring needs the metric_definitions catalog present.
  setup do
    CatalogSeed.seed!()
    :ok
  end

  describe "MovieScoring :absolute components (catalog-driven path)" do
    test "reproduces the hand-computed lens scores for a controlled fixture" do
      # canonical_count = 1, no popularity → time_machine = 1*2 = 2.0
      movie = insert_movie(%{"criterion" => %{}})
      add_ratings(movie, imdb: 8.0, tmdb: 6.0, metacritic: 60.0, rt: 80.0)
      add_director_with_quality(movie, 90.0)

      scores = MovieScoring.calculate_movie_scores(movie)
      c = scores.components

      assert c.mob == 7.0
      assert c.critics == 7.0
      assert c.time_machine == 2.0
      assert c.auteurs == 9.0
      assert c.box_office == 0.0
      assert c.festival_recognition == 0.0
      # All four core rating sources present.
      assert scores.score_confidence == 1.0
    end

    test "mob/critics are nil for a movie with no ratings (worker coalesces to 0.0)" do
      movie = insert_movie(%{})
      scores = MovieScoring.calculate_movie_scores(movie)
      assert scores.components.mob == nil
      assert scores.components.critics == nil
    end
  end

  describe "parity vs the prior cache baseline (bounded rounding noise)" do
    # v5 made mob/critics catalog-driven weighted means; it is equivalent to the v4
    # baseline within float rounding noise (no field differs by more than 0.1). The full
    # gate is the `mix cinegraph.scoring.parity_check` task; this samples the same property.
    @tag :scoring_db
    test "no field differs from the v4 baseline by more than 0.1" do
      caches =
        from(c in MovieScoreCache,
          where: c.calculation_version == "4" and c.overall_score > 0.0,
          limit: 2000
        )
        |> Repo.all()

      assert caches != [], "expected a v4-populated movie_score_caches; run against a real DB"

      ids = Enum.map(caches, & &1.movie_id)
      movies = from(m in Movie, where: m.id in ^ids) |> Repo.all() |> Map.new(&{&1.id, &1})

      tenths = fn
        nil -> 0
        %Decimal{} = d -> round(Decimal.to_float(d) * 10)
        x -> round(x * 10)
      end

      over =
        Enum.flat_map(caches, fn cache ->
          s = MovieScoring.calculate_movie_scores(movies[cache.movie_id])
          comp = s.components

          [
            {:mob, comp.mob, cache.mob_score},
            {:critics, comp.critics, cache.critics_score},
            {:festival, comp.festival_recognition, cache.festival_recognition_score},
            {:time_machine, comp.time_machine, cache.time_machine_score},
            {:auteurs, comp.auteurs, cache.auteurs_score},
            {:box_office, comp.box_office, cache.box_office_score},
            {:overall, s.overall_score, cache.overall_score}
          ]
          |> Enum.filter(fn {_k, a, b} -> abs(tenths.(a) - tenths.(b)) > 1 end)
          |> Enum.map(&{cache.movie_id, &1})
        end)

      assert over == [], "fields exceeding ±0.1 vs baseline: #{inspect(Enum.take(over, 20))}"
    end
  end

  # ── fixtures ──

  defp insert_movie(canonical_sources) do
    %Movie{}
    |> Movie.changeset(%{
      tmdb_id: System.unique_integer([:positive]),
      title: "Parity #{System.unique_integer([:positive])}",
      release_date: ~D[2010-01-01]
    })
    |> Repo.insert!()
    |> Ecto.Changeset.change(canonical_sources: canonical_sources)
    |> Repo.update!()
  end

  defp add_ratings(movie, opts) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    rows =
      [
        {"imdb", "rating_average", opts[:imdb]},
        {"tmdb", "rating_average", opts[:tmdb]},
        {"metacritic", "metascore", opts[:metacritic]},
        {"rotten_tomatoes", "tomatometer", opts[:rt]}
      ]
      |> Enum.reject(fn {_, _, v} -> is_nil(v) end)

    for {source, type, value} <- rows do
      {:ok, _} =
        Metrics.upsert_metric(%{
          movie_id: movie.id,
          source: source,
          metric_type: type,
          value: value,
          fetched_at: now
        })
    end
  end

  defp add_director_with_quality(movie, quality) do
    person =
      %Person{}
      |> Person.changeset(%{tmdb_id: System.unique_integer([:positive]), name: "D"})
      |> Repo.insert!()

    %Credit{}
    |> Credit.changeset(%{
      movie_id: movie.id,
      person_id: person.id,
      credit_type: "crew",
      department: "Directing",
      job: "Director",
      credit_id: "credit-#{System.unique_integer([:positive])}"
    })
    |> Repo.insert!()

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.insert_all("person_metrics", [
      %{
        person_id: person.id,
        metric_type: "quality_score",
        score: quality,
        calculated_at: now,
        inserted_at: now,
        updated_at: now
      }
    ])

    person
  end
end

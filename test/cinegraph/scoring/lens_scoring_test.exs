defmodule Cinegraph.Scoring.LensScoringTest do
  use Cinegraph.DataCase

  alias Cinegraph.Predictions.LensScoring
  alias Cinegraph.Scoring.LensFormulas
  alias Cinegraph.Metrics
  alias Cinegraph.Movies.{Credit, Movie, Person}
  alias Cinegraph.Repo

  # ── LensFormulas :absolute — these pin the discovery formulas so they cannot
  # drift. MovieScoring now delegates here; these values must never change. ──
  describe "LensFormulas absolute branch (discovery parity)" do
    test "mob = plain average of imdb/tmdb on 0-10, nil when no sources" do
      assert LensFormulas.mob(%{imdb_rating: 8.0, tmdb_rating: 6.0}, :absolute) == 7.0
      assert LensFormulas.mob(%{imdb_rating: 8.0, tmdb_rating: nil}, :absolute) == 8.0
      assert LensFormulas.mob(%{imdb_rating: nil, tmdb_rating: nil}, :absolute) == nil
    end

    test "critics normalizes 0-100 sources to 0-10 average" do
      assert LensFormulas.critics(%{rt_tomatometer: 80.0, metacritic: 60.0}, :absolute) == 7.0
      assert LensFormulas.critics(%{rt_tomatometer: nil, metacritic: nil}, :absolute) == nil
    end

    test "time_machine = canonical_count*2 + log-popularity*5, capped at 10" do
      assert LensFormulas.time_machine(%{canonical_count: 1, popularity: 0}, :absolute) == 2.0
      assert LensFormulas.time_machine(%{canonical_count: 9, popularity: 0}, :absolute) == 10.0
    end

    test "box_office returns 0.0 with no financials" do
      assert LensFormulas.box_office(%{budget: 0, revenue: 0}, :absolute) == 0.0
    end

    test "auteurs = intrinsic person_quality / 10" do
      assert LensFormulas.auteurs(%{person_quality: 90.0}, :absolute) == 9.0
      assert LensFormulas.auteurs(%{person_quality: nil}, :absolute) == 0.0
    end
  end

  describe "LensFormulas target branch" do
    test "mob adds an era-weighted vote component on a 0-100 scale" do
      # Modern film, no votes → just the rating component (avg*10*0.70)
      modern = %{imdb_rating: 8.0, tmdb_rating: 8.0, imdb_votes: 0, release_year: 2010}
      assert_in_delta LensFormulas.mob(modern, {:target, "x"}), 56.0, 0.001

      # Pre-1940 film votes are scaled 5x → older acclaimed films get a boost
      old = %{imdb_rating: 8.0, tmdb_rating: 8.0, imdb_votes: 20_000, release_year: 1935}
      assert LensFormulas.mob(old, {:target, "x"}) > LensFormulas.mob(modern, {:target, "x"})
    end

    test "auteurs is relational: counts director presence on the target list" do
      assert LensFormulas.auteurs(
               %{director_target_count: 5, director_avg_imdb: nil},
               {:target, "l"}
             ) ==
               50.0

      assert LensFormulas.auteurs(
               %{director_target_count: 0, director_avg_imdb: nil},
               {:target, "l"}
             ) ==
               0.0
    end
  end

  # ── Contract preserved from the former 5-criterion scorer, now on 6 lenses. ──
  describe "LensScoring contract" do
    test "scoring_criteria returns the 6 lens atoms" do
      assert LensScoring.scoring_criteria() ==
               ~w(mob critics festival_recognition time_machine auteurs box_office)a
    end

    test "default weights have 6 keys and sum to 1.0" do
      w = LensScoring.get_default_weights()
      assert map_size(w) == 6
      assert_in_delta Enum.sum(Map.values(w)), 1.0, 0.001
    end

    test "all named profiles use the 6 keys and sum to 1.0" do
      for p <- LensScoring.get_named_profiles() do
        assert MapSet.new(Map.keys(p.weights)) == MapSet.new(LensScoring.scoring_criteria())

        assert_in_delta Enum.sum(Map.values(p.weights)),
                        1.0,
                        0.001,
                        "profile '#{p.name}' weights must sum to 1.0"
      end
    end

    test "calculate_movie_score preserves the result shape with 6 criteria" do
      score =
        LensScoring.calculate_movie_score(%{
          id: 1,
          title: "x",
          tmdb_data: %{},
          canonical_sources: nil
        })

      assert %{
               total_score: _,
               likelihood_percentage: _,
               criteria_scores: cs,
               weights_used: _,
               breakdown: bd
             } = score

      assert map_size(cs) == 6
      assert length(bd) == 6
    end

    test "get_profile_weights falls back to defaults for unknown name" do
      assert LensScoring.get_profile_weights("nope") == LensScoring.get_default_weights()
    end
  end

  # ── The leakage gate. A movie's target-mode score must not change when the
  # target list is added to / removed from its canonical_sources — neither via
  # time_machine (canonical count) nor via auteurs (director track record). ──
  describe "leakage gate" do
    test "target-mode score is identical with or without the target list present" do
      source_key = "leak_list"
      other_list = "other_list"

      director = insert_person("Director D")

      # Another film by the same director, already on the target list.
      other_film = insert_movie("N by D", %{other_list => %{}, source_key => %{"rank" => 7}})
      add_director(other_film, director)

      # Subject movie M, directed by D, with ratings, on `other_list` only.
      subject = insert_movie("M by D", %{other_list => %{}})
      add_director(subject, director)
      add_ratings(subject)

      score_without = score(subject.id, source_key)

      # Now place M on the target list IN THE DB (so the director-count query sees it).
      subject
      |> Ecto.Changeset.change(
        canonical_sources: %{other_list => %{}, source_key => %{"rank" => 1}}
      )
      |> Repo.update!()

      score_with = score(subject.id, source_key)

      assert score_without.total_score == score_with.total_score
      assert score_without.criteria_scores == score_with.criteria_scores
    end
  end

  # ── helpers ──

  defp score(movie_id, source_key) do
    movie = Repo.get!(Movie, movie_id)
    LensScoring.calculate_movie_score(movie, LensScoring.get_default_weights(), source_key)
  end

  defp insert_person(name) do
    %Person{}
    |> Person.changeset(%{tmdb_id: System.unique_integer([:positive]), name: name})
    |> Repo.insert!()
  end

  defp insert_movie(title, canonical_sources) do
    %Movie{}
    |> Movie.changeset(%{
      tmdb_id: System.unique_integer([:positive]),
      title: "#{title} #{System.unique_integer([:positive])}",
      release_date: ~D[2010-01-01]
    })
    |> Repo.insert!()
    |> Ecto.Changeset.change(canonical_sources: canonical_sources)
    |> Repo.update!()
  end

  defp add_director(movie, person) do
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
  end

  defp add_ratings(movie) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    for {source, type, value} <- [
          {"imdb", "rating_average", 8.0},
          {"imdb", "rating_votes", 50_000.0},
          {"tmdb", "rating_average", 7.5},
          {"metacritic", "metascore", 82.0},
          {"rotten_tomatoes", "tomatometer", 90.0}
        ] do
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
end

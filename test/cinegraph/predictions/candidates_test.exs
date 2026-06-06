defmodule Cinegraph.Predictions.CandidatesTest do
  @moduledoc "The extracted candidates read-model (#1038 Stage 1) — gate, members, error paths."
  use Cinegraph.DataCase, async: true

  alias Cinegraph.Movies.Movie
  alias Cinegraph.Predictions.Candidates
  alias Cinegraph.Repo

  @sk "cand_test_list"

  defp movie!(attrs) do
    %Movie{}
    |> Movie.changeset(
      Map.merge(
        %{
          tmdb_id: System.unique_integer([:positive]),
          title: "M#{System.unique_integer([:positive])}",
          import_status: "full"
        },
        Map.new(attrs)
      )
    )
    |> Repo.insert!()
  end

  test "rank/2 returns {:error, :no_active_model} when nothing is served" do
    assert {:error, :no_active_model} = Candidates.rank(@sk)
    assert {:error, :no_active_model} = Candidates.next_additions(@sk)
  end

  test "probe/2 returns {:error, :no_active_model} when nothing is served" do
    m = movie!(canonical_sources: %{})
    assert {:error, :no_active_model} = Candidates.probe(@sk, m)
  end

  test "rank/2 raises on an invalid mode" do
    assert_raise ArgumentError, ~r/invalid mode/, fn -> Candidates.rank(@sk, mode: "bogus") end
  end

  test "members/2 returns the list's members newest-first with poster fields" do
    _other = movie!(canonical_sources: %{"another_list" => 1}, release_date: ~D[2020-01-01])

    old =
      movie!(
        canonical_sources: %{@sk => 1},
        release_date: ~D[1999-06-01],
        poster_path: "/old.jpg"
      )

    new =
      movie!(
        canonical_sources: %{@sk => 1},
        release_date: ~D[2021-03-01],
        poster_path: "/new.jpg"
      )

    members = Candidates.members(@sk)

    assert Enum.map(members, & &1.id) == [new.id, old.id]
    assert hd(members).poster_path == "/new.jpg"
    assert hd(members).slug
  end

  test "member_count/1 and base_rate/1" do
    movie!(canonical_sources: %{@sk => 1}, release_date: ~D[2000-01-01])
    movie!(canonical_sources: %{}, release_date: ~D[2001-01-01])

    assert Candidates.member_count(@sk) == 1
    rate = Candidates.base_rate(1)
    assert is_float(rate) and rate > 0.0 and rate <= 1.0
  end

  # The eligibility principle (#1078 §0): absence of one metric never disqualifies a film.
  # Default gate = observed by >=2 independent sources; no metric VALUE is ever required.
  test "universe_query/2 default eligibility is evidence presence, not any metric's value" do
    # Zero vote rows anywhere — but seen by two systems (RT + Metacritic). Must be eligible.
    no_votes =
      movie!(canonical_sources: %{}, release_date: ~D[2024-10-01], title: "Voteless Arthouse")

    metric!(no_votes, "rotten_tomatoes", "tomatometer", 95.0)
    metric!(no_votes, "metacritic", "metascore", 90.0)

    # Only ever observed by TMDb (bulk import) — below the 2-source evidence bar.
    tmdb_only =
      movie!(canonical_sources: %{}, release_date: ~D[2024-08-01], title: "Bulk Import Only")

    metric!(tmdb_only, "tmdb", "rating_average", 6.1)

    ids =
      @sk
      |> Candidates.universe_query(mode: "predictions", cutoff: 2024)
      |> Repo.all()
      |> Enum.map(& &1.id)

    assert no_votes.id in ids
    refute tmdb_only.id in ids

    # Members are never evidence-gated — membership is the truth, not a candidate.
    member =
      movie!(canonical_sources: %{@sk => 1}, release_date: ~D[2024-01-01], title: "Thin Member")

    member_ids =
      @sk |> Candidates.universe_query(mode: "members") |> Repo.all() |> Enum.map(& &1.id)

    assert member.id in member_ids
  end

  # Regression: WHEN the optional vote filter is requested, it must accept ANY maintained vote
  # source. TMDb counts are written once at import and go stale; gating on tmdb alone shrank the
  # 1001 pool to 41 films and excluded The Brutalist (tmdb 6 / imdb 105k) while including Smile 2.
  test "universe_query/2 vote floor accepts fresh IMDb votes when TMDb votes are stale" do
    stale_tmdb =
      movie!(canonical_sources: %{}, release_date: ~D[2024-12-20], title: "Stale TMDb Votes Film")

    votes!(stale_tmdb, "tmdb", 6.0)
    votes!(stale_tmdb, "imdb", 105_000.0)

    below_floor =
      movie!(canonical_sources: %{}, release_date: ~D[2024-06-01], title: "Genuinely Tiny Film")

    votes!(below_floor, "tmdb", 6.0)
    votes!(below_floor, "imdb", 40.0)

    ids =
      @sk
      |> Candidates.universe_query(mode: "predictions", cutoff: 2024, min_votes: 1000)
      |> Repo.all()
      |> Enum.map(& &1.id)

    assert stale_tmdb.id in ids
    refute below_floor.id in ids
  end

  # End-to-end why (#1076 P1): plant an active model, rank, and assert rows + probe carry the
  # exact labeled contribution breakdown.
  test "rank/2 rows and probe/2 carry the labeled why breakdown + evidence density" do
    Cinegraph.Metrics.CatalogSeed.seed!()

    movie =
      movie!(canonical_sources: %{}, release_date: ~D[2024-06-01], title: "Why Breakdown Film")

    metric!(movie, "imdb", "rating_average", 8.0)
    metric!(movie, "metacritic", "metascore", 50.0)

    {:ok, prereg} =
      Cinegraph.Predictions.PreRegistration.register(%{
        source_key: @sk,
        expected_top_features: %{},
        expected_accuracy_range: %{},
        failure_threshold: "0.10"
      })

    model =
      %Cinegraph.Predictions.Model{}
      |> Cinegraph.Predictions.Model.changeset(%{
        source_key: @sk,
        feature_set: %{"granularity" => "data_point", "features" => ["imdb_rating"]},
        weights: %{"imdb_rating" => 0.6, "metacritic_metascore" => 0.4},
        weights_hash: "why_h1",
        model_version: 1,
        integrity_report: %{
          "recall_at_k" => 0.5,
          "n_positives" => 20,
          "n_evaluated" => 100,
          "baselines" => %{"popularity" => 0.0}
        },
        prereg_id: prereg.id
      })
      |> Repo.insert!()

    list =
      %Cinegraph.Movies.MovieList{}
      |> Cinegraph.Movies.MovieList.changeset(%{
        source_key: @sk,
        name: "Why Test List",
        source_type: "imdb",
        source_url: "https://example.com/l",
        slug: "why-test-#{System.unique_integer([:positive])}",
        active: true
      })
      |> Repo.insert!()

    list |> Ecto.Changeset.change(active_prediction_model_id: model.id) |> Repo.update!()

    {:ok, result} = Candidates.rank(@sk, mode: "candidates", min_sources: 0, limit: 5)
    row = Enum.find(result.rows, &(&1.id == movie.id))
    assert row, "ranked rows should include the planted movie"

    assert [%{code: "imdb_rating", label: label, contribution: c1}, %{contribution: c2}] =
             row.why

    assert is_binary(label) and label != ""
    assert_in_delta c1, 48.0, 0.1
    assert_in_delta c2, 20.0, 0.1
    # signals_present = nonzero terms BEFORE the top-5 cap (signals moving the score)
    assert row.signals_present == 2

    {:ok, probe} = Candidates.probe(@sk, Repo.get!(Movie, movie.id))
    assert length(probe.why) == 2
    assert probe.present_features == 2
    assert probe.total_features == 2
  end

  defp votes!(movie, source, value), do: metric!(movie, source, "rating_votes", value)

  defp metric!(movie, source, metric_type, value) do
    %Cinegraph.Movies.ExternalMetric{}
    |> Cinegraph.Movies.ExternalMetric.changeset(%{
      movie_id: movie.id,
      source: source,
      metric_type: metric_type,
      value: value,
      fetched_at: DateTime.utc_now()
    })
    |> Repo.insert!()
  end
end

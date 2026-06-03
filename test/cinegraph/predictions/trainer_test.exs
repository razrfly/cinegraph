defmodule Cinegraph.Predictions.TrainerTest do
  @moduledoc "Integrity-protocol training: prereg enforcement, sacred holdout, data-point round-trip."
  use Cinegraph.DataCase

  alias Cinegraph.Metrics.CatalogSeed
  alias Cinegraph.Movies.{Movie, MovieLists}
  alias Cinegraph.Predictions.{Model, PreRegistration, Trainer}
  alias Cinegraph.Repo

  @list "trainer_test_list"

  setup do
    CatalogSeed.seed!()
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.insert_all("movie_lists", [
      %{
        name: "Trainer Test List",
        source_key: @list,
        source_type: "imdb",
        source_url: "https://example.com/#{@list}",
        category: "test",
        slug: @list,
        active: true,
        inserted_at: now,
        updated_at: now
      }
    ])

    plant_population()
    :ok
  end

  defp plant_population do
    # Two decades so split_holdout works: 1990s = train, 2000s = sacred holdout.
    # The 2000s holdout has ≥10 members so the trained model can clear the reliability
    # activation guard (#1051 Stage 0) and exercise the full round-trip-to-active path.
    for {decade, n_members, n_others} <- [{1990, 6, 16}, {2000, 12, 30}] do
      for i <- 1..n_members, do: plant(decade, i, member: true)
      for i <- 1..n_others, do: plant(decade, 100 + i, member: false)
    end
  end

  defp plant(decade, i, member: member?) do
    canonical = if member?, do: %{@list => true}, else: %{}

    movie =
      %Movie{}
      |> Movie.changeset(%{
        tmdb_id: System.unique_integer([:positive]),
        title: "#{decade} #{i}",
        release_date: Date.new!(decade + rem(i, 9), 6, 1),
        import_status: "full",
        canonical_sources: canonical
      })
      |> Repo.insert!()

    now = DateTime.utc_now() |> DateTime.truncate(:second)
    # Members rate higher on imdb (the real signal) but are LESS popular than non-members, so
    # the model must beat the popularity baseline on genuine signal (popular ≠ canon). This lets
    # a good model clear the reliability lift gate instead of merely tying popularity.
    imdb = if member?, do: 8.5, else: 5.5
    pop = if member?, do: 30.0, else: 50.0

    Repo.insert_all("external_metrics", [
      ext(movie.id, "imdb", "rating_average", imdb, now),
      ext(movie.id, "tmdb", "popularity_score", pop, now),
      # ≥ the static universe min-votes floor so non-members enter the candidate pool
      ext(movie.id, "tmdb", "rating_votes", 1500.0, now)
    ])

    movie
  end

  defp ext(movie_id, source, metric_type, value, now) do
    %{
      movie_id: movie_id,
      source: source,
      metric_type: metric_type,
      value: value,
      fetched_at: now,
      inserted_at: now,
      updated_at: now
    }
  end

  defp prereg! do
    {:ok, p} =
      PreRegistration.register(%{
        source_key: @list,
        expected_top_features: %{"top" => ["imdb_rating"]},
        expected_accuracy_range: %{"min" => 0.3, "max" => 0.9},
        failure_threshold: "0.10"
      })

    p
  end

  test "save without a pre-registration is refused" do
    assert {:error, :prereg_required} =
             Trainer.train(@list, granularity: :data_point, save: true)
  end

  describe "static k-fold strategy" do
    test "is seeded/deterministic and yields a static (not temporal) integrity report" do
      opts = [granularity: :data_point, backtest_strategy: "static"]
      assert {:ok, s1} = Trainer.train(@list, opts)
      assert {:ok, s2} = Trainer.train(@list, opts)

      i = s1.integrity_report
      # Same seed → identical metrics (deterministic universe + folds).
      assert i["recall_at_k"] == s2.integrity_report["recall_at_k"]
      assert i["k_folds"] == 5
      assert is_integer(i["seed"])
      assert is_list(i["by_fold"]) and length(i["by_fold"]) == 5
      assert Map.has_key?(i["baselines"], "popularity")
      # Static is member-k-fold, not a decade holdout.
      refute Map.has_key?(i, "holdout_decades")
    end

    test "static save persists backtest_strategy=static with prereg + holdout stamp" do
      assert {:ok, summary} =
               Trainer.train(@list,
                 granularity: :data_point,
                 backtest_strategy: "static",
                 save: true,
                 prereg: prereg!()
               )

      model = Repo.get!(Model, summary.model_id)
      assert model.backtest_strategy == "static"
      assert model.prereg_id != nil
      assert model.holdout_spent_at != nil
    end
  end

  test "data-point training round-trips with integrity report, holdout, and active model" do
    prereg = prereg!()

    assert {:ok, summary} =
             Trainer.train(@list, granularity: :data_point, save: true, prereg: prereg)

    assert summary.granularity == :data_point
    # Leakage: the target list's own code is never a feature.
    refute @list in summary.feature_names
    assert is_map(summary.weights) and map_size(summary.weights) > 0

    integ = summary.integrity_report
    assert is_number(integ["recall_at_k"])
    assert Map.has_key?(integ, "baselines")
    assert Map.has_key?(integ, "worst_miss")
    assert integ["holdout_decades"] == [2000]

    # Persisted artifact carries the integrity fields that were previously always null.
    model = Repo.get!(Model, summary.model_id)
    assert model.prereg_id == prereg.id
    assert model.holdout_spent_at != nil
    assert model.integrity_report["recall_at_k"] == integ["recall_at_k"]
    assert model.feature_set["granularity"] == "data_point"

    # Active pointer + derived cache set.
    list = MovieLists.get_by_source_key(@list)
    assert list && list.active_prediction_model_id == model.id
  end

  test "a pre-registration buys exactly one sacred-holdout evaluation" do
    prereg = prereg!()
    assert {:ok, _} = Trainer.train(@list, granularity: :data_point, save: true, prereg: prereg)

    assert {:error, :holdout_already_spent} =
             Trainer.train(@list, granularity: :data_point, save: true, prereg: prereg)
  end

  test "failure_threshold is mandatory in a pre-registration" do
    assert {:error, cs} =
             PreRegistration.register(%{
               source_key: @list,
               expected_top_features: %{},
               expected_accuracy_range: %{}
             })

    assert "can't be blank" in errors_on(cs).failure_threshold
  end

  test "a malformed failure_threshold is rejected (can't silently disable the gate)" do
    for bad <- ["high", "1.5", "-0.1", "0.3x"] do
      assert {:error, cs} =
               PreRegistration.register(%{
                 source_key: @list,
                 expected_top_features: %{},
                 expected_accuracy_range: %{},
                 failure_threshold: bad
               }),
             "expected #{inspect(bad)} to be rejected"

      assert Map.has_key?(errors_on(cs), :failure_threshold)
    end
  end

  describe "feature surface (#1051 A4)" do
    test "data_point_codes excludes is_available:false derived codes (missingness indicators)" do
      codes = Trainer.data_point_codes(@list)
      indicators = ~w(has_imdb_rating has_metacritic has_rotten_tomatoes has_budget has_revenue)

      # The indicators are catalogued is_available:false until the keep-criterion admits them.
      refute Enum.any?(indicators, &(&1 in codes))
      # …while the available canon-taste derived features are present.
      assert "canonical_contribution" in codes
    end

    test "objective_only / canon_overlap partition the surface exactly" do
      all = MapSet.new(Trainer.data_point_codes(@list))
      canon = Trainer.canon_overlap_codes(@list)
      canon_in = Enum.filter(all, &(&1 in canon))
      objective = MapSet.new(MapSet.to_list(all) -- canon_in)

      # canon-overlap ∪ objective == all, and the two are disjoint.
      assert MapSet.union(MapSet.new(canon_in), objective) == all
      assert MapSet.disjoint?(MapSet.new(canon_in), objective)
      # objective carries no canon-overlap code; the derived canon codes are in canon-overlap.
      refute Enum.any?(objective, &(&1 in canon))
      assert "canonical_contribution" in canon_in
      assert "auteur_track_record" in canon_in
      # the target's own code is never on the surface (leakage).
      refute @list in MapSet.to_list(all)
    end
  end
end

defmodule Cinegraph.Scoring.DerivedFeaturesTest do
  # FeatureResolver issues read queries (movie_credits/festival/external_metrics) keyed by
  # movie_id; with in-memory (un-inserted) structs those return empty, so only a sandbox
  # connection is needed — no fixtures.
  use Cinegraph.DataCase, async: true

  alias Cinegraph.Movies.Movie
  alias Cinegraph.Scoring.{Bus, DataPointFeatures, DerivedFeatures}

  @sk "1001_movies"

  defp movie(id, canon, budget \\ 0, revenue \\ 0) do
    %Movie{
      id: id,
      title: "M#{id}",
      release_date: ~D[2015-01-01],
      canonical_sources: canon,
      tmdb_data: %{"budget" => budget, "revenue" => revenue}
    }
  end

  describe "supported_codes/0 — the routing guard" do
    test "ships all 5 derived features, including the matview-backed prior_collab_density (#1044)" do
      assert Enum.sort(DerivedFeatures.supported_codes()) ==
               ~w(auteur_track_record box_office_roi canonical_contribution festival_prestige
                  prior_collab_density)

      assert "prior_collab_density" in DerivedFeatures.supported_codes()
    end
  end

  describe "load/3 normalization" do
    test "every emitted value is in [0,1]" do
      m = movie(1, %{"a" => 1, "b" => 1}, 1_000_000, 10_000_000)
      vals = DerivedFeatures.load([m], DerivedFeatures.supported_codes(), @sk) |> Map.fetch!(1)

      assert map_size(vals) == 5
      for {_code, v} <- vals, do: assert(v >= 0.0 and v <= 1.0)
    end

    test "canonical_contribution uses the shared log-normalization log(1+n)/log(1+10)" do
      # 2 other lists (target stripped) → log(3)/log(11). This locks the log_norm the other
      # count/ratio features reuse.
      m = movie(1, %{"a" => 1, "b" => 1})
      v = DerivedFeatures.load([m], ["canonical_contribution"], @sk)[1]["canonical_contribution"]
      assert_in_delta v, :math.log(3) / :math.log(11), 1.0e-6
    end

    test "box_office_roi is 0.0 with no budget/revenue (FeatureResolver reads external_metrics, not the struct)" do
      # Real ROI values come from `external_metrics` (tmdb/budget, tmdb/revenue_worldwide) and are
      # validated on real data by the live gate experiment, not an in-memory struct.
      none = movie(2, %{})
      assert DerivedFeatures.load([none], ["box_office_roi"], @sk)[2]["box_office_roi"] == 0.0
    end

    test "unsupported codes are filtered out; only supported requested codes are emitted" do
      m = movie(1, %{"a" => 1})
      vals = DerivedFeatures.load([m], ["canonical_contribution", "not_a_real_code"], @sk)[1]
      assert Map.keys(vals) == ["canonical_contribution"]
    end
  end

  describe "prior_collab_density — the matview data path (#1044)" do
    # These assert the no-signal path against an empty matview (no fixtures): the SQL returns no
    # rows, so callers default to 0.0. The leakage/aggregation math is covered by the data-backed
    # PriorCollabDensityTest (non-async, with a REFRESH'd matview).
    test "emits 0.0 for a movie with no prior collaboration data" do
      m = movie(1, %{"a" => 1})
      vals = DerivedFeatures.load([m], ["prior_collab_density"], @sk)[1]
      assert vals["prior_collab_density"] == 0.0
    end

    test "handles a movie with no release_date without error (0.0)" do
      m = %{movie(1, %{"a" => 1}) | release_date: nil}
      vals = DerivedFeatures.load([m], ["prior_collab_density"], @sk)[1]
      assert vals["prior_collab_density"] == 0.0
    end

    test "is emitted alongside the FeatureResolver-backed codes in one assembly" do
      m = movie(1, %{"a" => 1})
      vals = DerivedFeatures.load([m], ["canonical_contribution", "prior_collab_density"], @sk)[1]
      assert Enum.sort(Map.keys(vals)) == ["canonical_contribution", "prior_collab_density"]
    end
  end

  describe "leakage strip" do
    test "canonical_contribution ignores membership in the target list" do
      member = movie(1, %{"a" => 1, "1001_movies" => 1})
      nonmember = movie(2, %{"a" => 1})

      v_member = DerivedFeatures.load([member], ["canonical_contribution"], @sk)[1]
      v_non = DerivedFeatures.load([nonmember], ["canonical_contribution"], @sk)[2]

      # Both count only "a" (target stripped) → identical, and nonzero.
      assert v_member["canonical_contribution"] == v_non["canonical_contribution"]
      assert v_member["canonical_contribution"] > 0.0
    end
  end

  describe "train/serve symmetry (the #1040 invariant)" do
    test "Bus.score(:data_point) equals Σ w·load_for over the same shared assembly" do
      m = movie(1, %{"a" => 1}, 1_000_000, 5_000_000)
      weights = %{"canonical_contribution" => 1.0}

      v = DataPointFeatures.load_for([m], Map.keys(weights), @sk)[1]["canonical_contribution"]
      expected = Float.round(min(max(v * 100.0, 0.0), 100.0), 1)

      assert Bus.score([m], {:data_point, weights, @sk}) == %{1 => expected}
    end

    test "load_for is deterministic" do
      m = movie(1, %{"a" => 1, "b" => 1}, 2_000_000, 8_000_000)
      codes = DerivedFeatures.supported_codes()

      assert DataPointFeatures.load_for([m], codes, @sk) ==
               DataPointFeatures.load_for([m], codes, @sk)
    end
  end
end

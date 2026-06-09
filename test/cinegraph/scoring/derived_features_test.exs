defmodule Cinegraph.Scoring.DerivedFeaturesTest do
  # FeatureResolver issues read queries (movie_credits/festival/external_metrics) keyed by
  # movie_id; with in-memory (un-inserted) structs those return empty, so only a sandbox
  # connection is needed — no fixtures.
  use Cinegraph.DataCase, async: true

  alias Cinegraph.Metrics.CatalogSeed
  alias Cinegraph.Movies.{Genre, Movie}
  alias Cinegraph.Repo
  alias Cinegraph.Scoring.{Bus, DataPointFeatures, DerivedFeatures}

  @sk "1001_movies"

  defp uniq, do: System.unique_integer([:positive])

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
    test "ships the 5 canon-taste features + 5 missingness indicators + the Tier-0 categoricals" do
      supported = DerivedFeatures.supported_codes()

      # canon-taste (#1044) + missingness (#1051 A4)
      for c <- ~w(auteur_track_record box_office_roi canonical_contribution festival_prestige
                  has_budget has_imdb_rating has_metacritic has_revenue has_rotten_tomatoes
                  prior_collab_density),
          do: assert(c in supported)

      # Tier-0 categoricals (#1070): 13 languages + 19 genres + 1 ordinal = 33
      assert length(DerivedFeatures.categorical_codes()) == 33
      assert "lang_en" in supported and "lang_other" in supported
      assert "genre_drama" in supported and "genre_science_fiction" in supported
      assert "content_rating_age" in supported
    end
  end

  describe "load/3 normalization" do
    test "every emitted value is in [0,1]" do
      m = movie(1, %{"a" => 1, "b" => 1}, 1_000_000, 10_000_000)
      vals = DerivedFeatures.load([m], DerivedFeatures.supported_codes(), @sk) |> Map.fetch!(1)

      assert map_size(vals) == length(DerivedFeatures.supported_codes())
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

  describe "missingness indicators (#1051 A4)" do
    test "routed + emit 0.0 for an in-memory movie with no view presence" do
      m = movie(1, %{"a" => 1})
      vals = DerivedFeatures.load([m], ~w(has_imdb_rating has_metacritic), @sk)[1]
      assert vals == %{"has_imdb_rating" => 0.0, "has_metacritic" => 0.0}
    end

    test "has_X = 1.0 when the underlying code is present in the view, 0.0 when absent" do
      CatalogSeed.seed!()
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      m =
        %Movie{}
        |> Movie.changeset(%{
          tmdb_id: System.unique_integer([:positive]),
          title: "Has IMDb",
          imdb_id: "tt#{System.unique_integer([:positive])}",
          canonical_sources: %{}
        })
        |> Repo.insert!()

      # imdb/rating_average → metric_values_view emits `imdb_rating` (catalog-mapped) for this movie.
      Repo.insert_all("external_metrics", [
        %{
          movie_id: m.id,
          source: "imdb",
          metric_type: "rating_average",
          value: 7.5,
          fetched_at: now,
          inserted_at: now,
          updated_at: now
        }
      ])

      loaded = %Movie{
        id: m.id,
        title: "Has IMDb",
        release_date: ~D[2015-01-01],
        canonical_sources: %{}
      }

      vals = DerivedFeatures.load([loaded], ~w(has_imdb_rating has_metacritic), @sk)[m.id]

      assert vals["has_imdb_rating"] == 1.0
      assert vals["has_metacritic"] == 0.0
    end
  end

  describe "Tier-0 categorical features (#1070)" do
    test "in-memory movie (no DB rows) → all categorical codes emit 0.0" do
      m = movie(1, %{"a" => 1})
      vals = DerivedFeatures.load([m], DerivedFeatures.categorical_codes(), @sk)[1]
      assert map_size(vals) == 33
      for {_code, v} <- vals, do: assert(v == 0.0)
    end

    test "language one-hot, genre multi-hot, and content_rating_age from real DB rows" do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      m =
        %Movie{}
        |> Movie.changeset(%{
          tmdb_id: System.unique_integer([:positive]),
          title: "Le Film",
          original_language: "fr",
          canonical_sources: %{}
        })
        |> Repo.insert!()

      # genres + junction (Drama, Science Fiction → genre_drama, genre_science_fiction)
      {drama_id, scifi_id} = {uniq(), uniq()}

      Repo.insert_all("genres", [
        %{id: drama_id, tmdb_id: uniq(), name: "Drama", inserted_at: now, updated_at: now},
        %{
          id: scifi_id,
          tmdb_id: uniq(),
          name: "Science Fiction",
          inserted_at: now,
          updated_at: now
        }
      ])

      Repo.insert_all("movie_genres", [
        %{movie_id: m.id, genre_id: drama_id},
        %{movie_id: m.id, genre_id: scifi_id}
      ])

      # omdb content_rating "R" → MPAA min age 17 → 17/18
      Repo.insert_all("external_metrics", [
        %{
          movie_id: m.id,
          source: "omdb",
          metric_type: "content_rating",
          text_value: "R",
          fetched_at: now,
          inserted_at: now,
          updated_at: now
        }
      ])

      loaded = %Movie{
        id: m.id,
        title: "Le Film",
        release_date: ~D[2015-01-01],
        canonical_sources: %{}
      }

      vals = DerivedFeatures.load([loaded], DerivedFeatures.categorical_codes(), @sk)[m.id]

      assert vals["lang_fr"] == 1.0
      assert vals["lang_en"] == 0.0
      assert vals["lang_other"] == 0.0
      assert vals["genre_drama"] == 1.0
      assert vals["genre_science_fiction"] == 1.0
      assert vals["genre_horror"] == 0.0
      assert_in_delta vals["content_rating_age"], 17.0 / 18.0, 1.0e-6
    end

    test "lang_other fires for a known language outside the top-N" do
      m =
        %Movie{}
        |> Movie.changeset(%{
          tmdb_id: System.unique_integer([:positive]),
          title: "Filmi",
          # 'fi' (Finnish) is a real code but not in the top-N → lang_other
          original_language: "fi",
          canonical_sources: %{}
        })
        |> Repo.insert!()

      loaded = %Movie{
        id: m.id,
        title: "Filmi",
        release_date: ~D[2015-01-01],
        canonical_sources: %{}
      }

      vals = DerivedFeatures.load([loaded], DerivedFeatures.language_codes(), @sk)[m.id]

      assert vals["lang_other"] == 1.0
      assert vals["lang_en"] == 0.0
      assert vals["lang_fr"] == 0.0
    end

    test "categorical values are leakage-safe (identical with/without target list membership)" do
      m =
        %Movie{}
        |> Movie.changeset(%{
          tmdb_id: System.unique_integer([:positive]),
          title: "Member",
          original_language: "ja",
          canonical_sources: %{"1001_movies" => 1, "other" => 1}
        })
        |> Repo.insert!()

      with_target = %Movie{
        id: m.id,
        title: "Member",
        release_date: ~D[2015-01-01],
        canonical_sources: %{"1001_movies" => 1}
      }

      without = %Movie{
        id: m.id,
        title: "Member",
        release_date: ~D[2015-01-01],
        canonical_sources: %{}
      }

      codes = DerivedFeatures.categorical_codes()

      assert DerivedFeatures.load([with_target], codes, @sk)[m.id] ==
               DerivedFeatures.load([without], codes, @sk)[m.id]
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

  describe "E1/E2 (#1081): genre×RT interactions + rt_meta_gap" do
    setup do
      CatalogSeed.seed!()
      :ok
    end

    defp planted_movie!(attrs) do
      %Movie{}
      |> Movie.changeset(
        Map.merge(
          %{tmdb_id: uniq(), title: "IxnM#{uniq()}", import_status: "full"},
          Map.new(attrs)
        )
      )
      |> Repo.insert!()
    end

    defp plant_genre!(movie, name) do
      genre =
        Repo.insert!(%Genre{name: name, tmdb_id: uniq()},
          on_conflict: [set: [name: name]],
          conflict_target: :tmdb_id,
          returning: true
        )

      Repo.insert_all("movie_genres", [%{movie_id: movie.id, genre_id: genre.id}])
    end

    defp plant_metric!(movie, source, metric_type, value) do
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

    test "the 8 ixn codes + rt_meta_gap are supported and accessor-exposed" do
      supported = DerivedFeatures.supported_codes()
      assert length(DerivedFeatures.rt_genre_interaction_codes()) == 8

      for c <- DerivedFeatures.rt_genre_interaction_codes(), do: assert(c in supported)
      assert "ixn_rt_horror" in supported
      assert "rt_meta_gap" in supported
    end

    test "ixn_rt: genre present AND RT present → normalized RT; absent either → 0.0" do
      m = planted_movie!(%{})
      plant_genre!(m, "Horror")
      plant_metric!(m, "rotten_tomatoes", "tomatometer", 86.0)

      vals =
        DerivedFeatures.load([m], ["ixn_rt_horror", "ixn_rt_drama"], @sk) |> Map.fetch!(m.id)

      assert_in_delta vals["ixn_rt_horror"], 0.86, 1.0e-6
      # has RT but NOT the drama genre
      assert vals["ixn_rt_drama"] == 0.0
    end

    test "ixn_rt: genre present but RT missing → 0.0 (no signal, not a fake zero rating)" do
      m = planted_movie!(%{})
      plant_genre!(m, "Drama")

      vals = DerivedFeatures.load([m], ["ixn_rt_drama"], @sk) |> Map.fetch!(m.id)
      assert vals["ixn_rt_drama"] == 0.0
    end

    test "rt_meta_gap: the Smile-2 shape (RT 86 / Meta 67) → 0.19; meta ≥ rt → 0.0" do
      smile = planted_movie!(%{})
      plant_metric!(smile, "rotten_tomatoes", "tomatometer", 86.0)
      plant_metric!(smile, "metacritic", "metascore", 67.0)

      prestige = planted_movie!(%{})
      plant_metric!(prestige, "rotten_tomatoes", "tomatometer", 80.0)
      plant_metric!(prestige, "metacritic", "metascore", 90.0)

      vals = DerivedFeatures.load([smile, prestige], ["rt_meta_gap"], @sk)
      assert_in_delta vals[smile.id]["rt_meta_gap"], 0.19, 1.0e-4
      assert vals[prestige.id]["rt_meta_gap"] == 0.0
    end

    test "rt_meta_gap: either source missing → 0.0 (no inflation evidence)" do
      rt_only = planted_movie!(%{})
      plant_metric!(rt_only, "rotten_tomatoes", "tomatometer", 95.0)

      neither = planted_movie!(%{})

      vals = DerivedFeatures.load([rt_only, neither], ["rt_meta_gap"], @sk)
      assert vals[rt_only.id]["rt_meta_gap"] == 0.0
      assert vals[neither.id]["rt_meta_gap"] == 0.0
    end

    test "all E1/E2 values stay in [0,1]" do
      m = planted_movie!(%{})
      plant_genre!(m, "Science Fiction")
      plant_metric!(m, "rotten_tomatoes", "tomatometer", 100.0)
      plant_metric!(m, "metacritic", "metascore", 0.0)

      codes = DerivedFeatures.rt_genre_interaction_codes() ++ ["rt_meta_gap"]
      vals = DerivedFeatures.load([m], codes, @sk) |> Map.fetch!(m.id)

      assert map_size(vals) == 9
      for {_c, v} <- vals, do: assert(v >= 0.0 and v <= 1.0)
      assert_in_delta vals["ixn_rt_science_fiction"], 1.0, 1.0e-6
      assert_in_delta vals["rt_meta_gap"], 1.0, 1.0e-6
    end
  end

  describe "band (one-hot) features (#1087)" do
    test "band codes are routed (supported) and fully labelled" do
      supported = DerivedFeatures.supported_codes()
      for c <- DerivedFeatures.band_codes(), do: assert(c in supported)

      # band_labels is the single source of truth for the catalog seed → must cover every code.
      labelled = Map.new(DerivedFeatures.band_labels()) |> Map.keys() |> MapSet.new()
      assert labelled == MapSet.new(DerivedFeatures.band_codes())

      # 4 edges ⇒ 5 value bins + 1 missing, ordered missing → b0..b4.
      assert DerivedFeatures.band_codes_for("rev_ww") ==
               ~w(rev_ww_missing rev_ww_b0 rev_ww_b1 rev_ww_b2 rev_ww_b3 rev_ww_b4)

      assert "rev_ww" in DerivedFeatures.band_prefixes()
      assert "roi" in DerivedFeatures.band_prefixes()
    end

    test "an absent signal falls into the *_missing bin — exactly one-hot per family" do
      m = planted_movie!(%{})
      vals = DerivedFeatures.load([m], DerivedFeatures.band_codes(), @sk) |> Map.fetch!(m.id)

      for prefix <- DerivedFeatures.band_prefixes() do
        fam = DerivedFeatures.band_codes_for(prefix)
        assert Enum.count(fam, &(vals[&1] == 1.0)) == 1, "#{prefix} not one-hot"
        assert vals["#{prefix}_missing"] == 1.0, "#{prefix} should be missing"
      end
    end

    test "a present value lands in the correct bin (and missing is distinct from the low bin)" do
      m = planted_movie!(%{})

      # revenue $5M → b1 (1–10M]; budget $1M ⇒ ROI 5.0 → b2 (2–5]; RT 92 → b4 (80–100].
      plant_metric!(m, "tmdb", "revenue_worldwide", 5_000_000.0)
      plant_metric!(m, "tmdb", "budget", 1_000_000.0)
      plant_metric!(m, "rotten_tomatoes", "tomatometer", 92.0)

      vals = DerivedFeatures.load([m], DerivedFeatures.band_codes(), @sk) |> Map.fetch!(m.id)

      assert vals["rev_ww_b1"] == 1.0
      assert vals["rev_ww_missing"] == 0.0
      assert vals["roi_b2"] == 1.0
      assert vals["rt_b4"] == 1.0
      # families with no planted metric are missing, never a value bin.
      assert vals["meta_missing"] == 1.0
    end
  end
end

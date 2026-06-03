defmodule Cinegraph.Metrics.CatalogSeed do
  @moduledoc """
  The Layer-0 data-point catalog (#1036), as data + an idempotent upsert.

  This is the single source of truth for `metric_definitions` rows. The seed file
  (`priv/repo/seeds/metric_definitions.exs`) and tests both call `seed!/0` so the
  catalog can be materialized in any environment (incl. the test sandbox).

  Each row may set only the fields that differ from `catalog_defaults/0`
  (`kind: "raw"`, `derivation: nil`, `weight_within_lens: 1.0`, `is_available: true`).

  Conventions:
    * `category` is the lens a data point feeds, or `nil` for an **ML-only** feature
      (catalogued and usable by models, but not rolled into a human lens).
    * `weight_within_lens: 0.0` — catalogued under a lens but NOT a member of the
      `:absolute` computation (e.g. votes, audience score, domestic revenue).
    * `kind: "derived"` + `derivation` — computed by `FeatureResolver`, not a raw source.
    * `is_available: false` — JSONB-trapped / not-yet-extracted; honest coverage only.
  """

  alias Cinegraph.Repo

  @catalog_defaults %{kind: "raw", derivation: nil, weight_within_lens: 1.0, is_available: true}

  @doc "Default catalog-column values; each definition overrides as needed."
  def catalog_defaults, do: @catalog_defaults

  @doc """
  All catalog definitions (raw values; defaults NOT yet merged).

  The static sections are the hand-curated catalog; `dynamic_festival_codes/0` and
  `dynamic_list_codes/0` generate ML-only normalized rows from the DB so the long tail
  of festival win/nom codes and canonical-list keys are first-class normalized data
  points (not just rule-accepted). Deduped by `code`, keeping the hand-curated row when
  a generated code would collide.
  """
  def definitions do
    static =
      ratings() ++ financial() ++ awards() ++ canonical() ++ people() ++ derived() ++ ml_only()

    (static ++ dynamic_festival_codes() ++ dynamic_list_codes())
    |> Enum.uniq_by(& &1.code)
  end

  @doc "All catalog definitions with `catalog_defaults` merged in."
  def definitions_with_defaults do
    Enum.map(definitions(), &Map.merge(@catalog_defaults, &1))
  end

  @doc "Idempotently upsert the full catalog. Returns the row count."
  def seed! do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    entries =
      Enum.map(definitions_with_defaults(), fn d ->
        Map.merge(d, %{inserted_at: now, updated_at: now})
      end)

    Repo.insert_all(
      "metric_definitions",
      entries,
      conflict_target: [:code],
      on_conflict:
        {:replace,
         [
           :name,
           :description,
           :source_table,
           :source_type,
           :source_field,
           :category,
           :subcategory,
           :normalization_type,
           :normalization_params,
           :raw_scale_min,
           :raw_scale_max,
           :kind,
           :derivation,
           :weight_within_lens,
           :is_available,
           :source_reliability,
           :active,
           :updated_at
         ]}
    )

    length(entries)
  end

  # ── ratings & popularity (mob / critics) ───────────────────────────────────
  defp ratings do
    [
      def_(%{
        code: "imdb_rating",
        name: "IMDb Rating",
        source_type: "imdb",
        source_field: "rating_average",
        category: "mob",
        subcategory: "audience_rating",
        normalization_type: "linear",
        raw_scale_min: 0.0,
        raw_scale_max: 10.0,
        source_reliability: 0.95
      }),
      def_(%{
        code: "tmdb_rating",
        name: "TMDb Rating",
        source_type: "tmdb",
        source_field: "rating_average",
        category: "mob",
        subcategory: "audience_rating",
        normalization_type: "linear",
        raw_scale_min: 0.0,
        raw_scale_max: 10.0,
        source_reliability: 0.9
      }),
      def_(%{
        code: "metacritic_metascore",
        name: "Metacritic Score",
        source_type: "metacritic",
        source_field: "metascore",
        category: "critics",
        subcategory: "critic_rating",
        normalization_type: "linear",
        raw_scale_min: 0.0,
        raw_scale_max: 100.0,
        source_reliability: 0.85
      }),
      def_(%{
        code: "rotten_tomatoes_tomatometer",
        name: "Rotten Tomatoes Tomatometer",
        source_type: "rotten_tomatoes",
        source_field: "tomatometer",
        category: "critics",
        subcategory: "critic_rating",
        normalization_type: "linear",
        raw_scale_min: 0.0,
        raw_scale_max: 100.0,
        source_reliability: 0.8
      }),
      # Audience score: not consumed by the :absolute cache mob lens.
      def_(%{
        code: "rotten_tomatoes_audience_score",
        name: "Rotten Tomatoes Audience Score",
        source_type: "rotten_tomatoes",
        source_field: "audience_score",
        category: "mob",
        subcategory: "audience_rating",
        normalization_type: "linear",
        raw_scale_min: 0.0,
        raw_scale_max: 100.0,
        source_reliability: 0.75,
        weight_within_lens: 0.0
      }),
      # Vote counts: target-mode era-weighting signal only (not :absolute members).
      def_(%{
        code: "imdb_rating_votes",
        name: "IMDb Vote Count",
        source_type: "imdb",
        source_field: "rating_votes",
        category: "mob",
        subcategory: "audience_rating",
        normalization_type: "logarithmic",
        normalization_params: %{"threshold" => 10_000_000},
        raw_scale_min: 0.0,
        source_reliability: 0.95,
        weight_within_lens: 0.0
      }),
      def_(%{
        code: "tmdb_rating_votes",
        name: "TMDb Vote Count",
        source_type: "tmdb",
        source_field: "rating_votes",
        category: "mob",
        subcategory: "audience_rating",
        normalization_type: "logarithmic",
        normalization_params: %{"threshold" => 1_000_000},
        raw_scale_min: 0.0,
        source_reliability: 0.9,
        weight_within_lens: 0.0
      }),
      # Popularity feeds time_machine (cultural penetration), via the custom strategy.
      def_(%{
        code: "tmdb_popularity_score",
        name: "TMDb Popularity",
        source_type: "tmdb",
        source_field: "popularity_score",
        category: "time_machine",
        subcategory: "cultural_penetration",
        normalization_type: "logarithmic",
        normalization_params: %{"threshold" => 1000},
        raw_scale_min: 0.0,
        source_reliability: 0.7
      })
    ]
  end

  # ── financial (box_office) ─────────────────────────────────────────────────
  defp financial do
    [
      def_(%{
        code: "tmdb_budget",
        name: "Production Budget",
        source_type: "tmdb",
        source_field: "budget",
        category: "box_office",
        subcategory: "box_office",
        normalization_type: "logarithmic",
        normalization_params: %{"threshold" => 500_000_000},
        raw_scale_min: 0.0,
        source_reliability: 0.7
      }),
      def_(%{
        code: "tmdb_revenue_worldwide",
        name: "Worldwide Revenue",
        source_type: "tmdb",
        source_field: "revenue_worldwide",
        category: "box_office",
        subcategory: "box_office",
        normalization_type: "logarithmic",
        normalization_params: %{"threshold" => 2_000_000_000},
        raw_scale_min: 0.0,
        source_reliability: 0.7
      }),
      def_(%{
        code: "omdb_revenue_domestic",
        name: "Domestic Box Office",
        source_type: "omdb",
        source_field: "revenue_domestic",
        category: "box_office",
        subcategory: "box_office",
        normalization_type: "logarithmic",
        normalization_params: %{"threshold" => 1_000_000_000},
        raw_scale_min: 0.0,
        source_reliability: 0.65,
        weight_within_lens: 0.0
      })
    ]
  end

  # ── awards (festival_recognition) ──────────────────────────────────────────
  defp awards do
    [
      def_(%{
        code: "oscar_wins",
        name: "Oscar Wins",
        source_table: "festival_nominations",
        source_type: "AMPAS",
        source_field: "won",
        category: "festival_recognition",
        subcategory: "major_award",
        normalization_type: "custom",
        normalization_params: %{"0" => 0.0, "1" => 0.6, "2" => 0.8, "3+" => 1.0},
        raw_scale_min: 0.0,
        source_reliability: 1.0
      }),
      def_(%{
        code: "oscar_nominations",
        name: "Oscar Nominations",
        source_table: "festival_nominations",
        source_type: "AMPAS",
        source_field: "nominated",
        category: "festival_recognition",
        subcategory: "major_award",
        normalization_type: "custom",
        normalization_params: %{"0" => 0.0, "1" => 0.5, "2" => 0.7, "3+" => 1.0},
        raw_scale_min: 0.0,
        source_reliability: 1.0
      }),
      def_(%{
        code: "cannes_palme_dor",
        name: "Cannes Palme d'Or",
        source_table: "festival_nominations",
        source_type: "CANNES",
        source_field: "won",
        category: "festival_recognition",
        subcategory: "major_award",
        normalization_type: "boolean",
        raw_scale_min: 0.0,
        raw_scale_max: 1.0,
        source_reliability: 1.0
      }),
      def_(%{
        code: "venice_golden_lion",
        name: "Venice Golden Lion",
        source_table: "festival_nominations",
        source_type: "VIFF",
        source_field: "won",
        category: "festival_recognition",
        subcategory: "major_award",
        normalization_type: "boolean",
        raw_scale_min: 0.0,
        raw_scale_max: 1.0,
        source_reliability: 1.0
      }),
      def_(%{
        code: "berlin_golden_bear",
        name: "Berlin Golden Bear",
        source_table: "festival_nominations",
        source_type: "BERLINALE",
        source_field: "won",
        category: "festival_recognition",
        subcategory: "major_award",
        normalization_type: "boolean",
        raw_scale_min: 0.0,
        raw_scale_max: 1.0,
        source_reliability: 1.0
      })
    ]
  end

  # ── canonical lists (time_machine) ─────────────────────────────────────────
  defp canonical do
    [
      def_(%{
        code: "1001_movies",
        name: "1001 Movies Before You Die",
        source_table: "canonical_sources",
        source_type: "1001_movies",
        source_field: "included",
        category: "time_machine",
        subcategory: "canonical_list",
        normalization_type: "boolean",
        raw_scale_min: 0.0,
        raw_scale_max: 1.0,
        source_reliability: 0.85
      }),
      def_(%{
        code: "criterion",
        name: "Criterion Collection",
        source_table: "canonical_sources",
        source_type: "criterion",
        source_field: "included",
        category: "time_machine",
        subcategory: "canonical_list",
        normalization_type: "boolean",
        raw_scale_min: 0.0,
        raw_scale_max: 1.0,
        source_reliability: 0.9
      }),
      def_(%{
        code: "national_film_registry",
        name: "National Film Registry",
        source_table: "canonical_sources",
        source_type: "national_film_registry",
        source_field: "included",
        category: "time_machine",
        subcategory: "canonical_list",
        normalization_type: "boolean",
        raw_scale_min: 0.0,
        raw_scale_max: 1.0,
        source_reliability: 0.95
      }),
      def_(%{
        code: "sight_sound_critics_2022",
        name: "Sight & Sound Critics' Poll 2022",
        source_table: "canonical_sources",
        source_type: "sight_sound_critics_2022",
        source_field: "rank",
        category: "time_machine",
        subcategory: "critics_poll",
        normalization_type: "sigmoid",
        normalization_params: %{"k" => 0.02, "midpoint" => 125},
        raw_scale_min: 1.0,
        raw_scale_max: 250.0,
        source_reliability: 0.95
      }),
      def_(%{
        code: "afi_100",
        name: "AFI Top 100",
        source_table: "canonical_sources",
        source_type: "afi_100",
        source_field: "rank",
        category: "time_machine",
        subcategory: "critics_poll",
        normalization_type: "sigmoid",
        normalization_params: %{"k" => 0.05, "midpoint" => 50},
        raw_scale_min: 1.0,
        raw_scale_max: 100.0,
        source_reliability: 0.9
      }),
      def_(%{
        code: "bfi_top_100",
        name: "BFI Top 100",
        source_table: "canonical_sources",
        source_type: "bfi_top_100",
        source_field: "rank",
        category: "time_machine",
        subcategory: "critics_poll",
        normalization_type: "sigmoid",
        normalization_params: %{"k" => 0.05, "midpoint" => 50},
        raw_scale_min: 1.0,
        raw_scale_max: 100.0,
        source_reliability: 0.9
      })
    ]
  end

  # ── people (auteurs) ───────────────────────────────────────────────────────
  defp people do
    [
      def_(%{
        code: "person_quality_score",
        name: "Person Quality Score",
        source_table: "person_metrics",
        source_type: "quality_score",
        source_field: "score",
        category: "auteurs",
        subcategory: "talent_quality",
        normalization_type: "linear",
        raw_scale_min: 0.0,
        raw_scale_max: 100.0,
        source_reliability: 0.9
      })
    ]
  end

  # ── derived, computed by FeatureResolver (not a single source row) ─────────
  defp derived do
    [
      def_(%{
        code: "canonical_contribution",
        name: "Canonical Contribution (target-aware)",
        source_table: "derived",
        category: "time_machine",
        subcategory: "derived_feature",
        normalization_type: "custom",
        source_reliability: 1.0,
        kind: "derived",
        derivation: "canonical_contribution"
      }),
      def_(%{
        code: "auteur_track_record",
        name: "Auteur Track Record (target-aware)",
        source_table: "derived",
        category: "auteurs",
        subcategory: "derived_feature",
        normalization_type: "custom",
        source_reliability: 1.0,
        kind: "derived",
        derivation: "auteur_track_record"
      }),
      def_(%{
        code: "box_office_roi",
        name: "Box Office ROI",
        source_table: "derived",
        category: "box_office",
        subcategory: "derived_feature",
        normalization_type: "custom",
        source_reliability: 0.7,
        kind: "derived",
        derivation: "box_office_roi",
        weight_within_lens: 0.0
      }),
      def_(%{
        code: "festival_prestige",
        name: "Festival Prestige (tier-weighted)",
        source_table: "derived",
        category: "festival_recognition",
        subcategory: "derived_feature",
        normalization_type: "custom",
        source_reliability: 1.0,
        kind: "derived",
        derivation: "festival_prestige",
        weight_within_lens: 0.0
      })
    ]
  end

  # ── ML-only features (category nil; usable by models, not in a human lens) ──
  defp ml_only do
    [
      # TMDb user/curated list appearances. ML-only (category nil) — a cultural-penetration
      # signal available to model feature sets, deliberately NOT a time_machine lens member
      # so the lens config (and lens_config_hash) is unchanged by the #1036 popularity fix.
      def_(%{
        code: "list_appearances",
        name: "TMDb List Appearances",
        source_type: "tmdb",
        source_field: "list_appearances",
        normalization_type: "logarithmic",
        normalization_params: %{"threshold" => 50},
        raw_scale_min: 0.0,
        source_reliability: 0.6
      }),
      def_(%{
        code: "runtime",
        name: "Runtime (minutes)",
        source_table: "movies",
        source_field: "runtime",
        normalization_type: "linear",
        raw_scale_min: 0.0,
        raw_scale_max: 240.0,
        source_reliability: 0.9
      }),
      def_(%{
        code: "release_year",
        name: "Release Year",
        source_table: "movies",
        source_field: "release_date",
        normalization_type: "custom",
        source_reliability: 1.0
      }),
      def_(%{
        code: "original_language",
        name: "Original Language",
        source_table: "movies",
        source_field: "original_language",
        normalization_type: "custom",
        source_reliability: 1.0
      }),
      def_(%{
        code: "genre_ids",
        name: "Genres",
        source_table: "movie_genres",
        source_field: "genre_id",
        normalization_type: "custom",
        source_reliability: 0.9
      }),
      def_(%{
        code: "keyword_ids",
        name: "Keywords",
        source_table: "movie_keywords",
        source_field: "keyword_id",
        normalization_type: "custom",
        source_reliability: 0.7
      }),
      def_(%{
        code: "content_rating",
        name: "Content Rating",
        source_type: "omdb",
        source_field: "content_rating",
        normalization_type: "custom",
        source_reliability: 0.8
      }),
      def_(%{
        code: "collection_membership",
        name: "Belongs to Collection",
        source_table: "movies",
        source_field: "collection_id",
        normalization_type: "boolean",
        source_reliability: 0.9
      }),
      def_(%{
        code: "production_country_count",
        name: "Production Country Count",
        source_table: "movie_production_countries",
        source_field: "movie_id",
        normalization_type: "linear",
        raw_scale_min: 0.0,
        raw_scale_max: 10.0,
        source_reliability: 0.8
      }),
      def_(%{
        code: "has_official_trailer",
        name: "Has Official Trailer",
        source_table: "movie_videos",
        source_field: "official",
        normalization_type: "boolean",
        source_reliability: 0.7
      }),
      def_(%{
        code: "prior_collab_density",
        name: "Prior Collaboration Density",
        source_table: "derived",
        normalization_type: "logarithmic",
        normalization_params: %{"threshold" => 50},
        source_reliability: 0.7,
        kind: "derived",
        derivation: "prior_collab_density",
        # #1040 Session 2: deferred. Needs per-movie wiring of the person×year
        # `person_collaboration_trends` matview (prior-to-release collaboration density), a
        # separate data path from the FeatureResolver-backed features. Marked unavailable so the
        # catalog doesn't claim a feature the data-point surface doesn't emit (no silent cap).
        is_available: false
      })
    ]
  end

  # ── dynamic (DB-driven) ML-only data points ────────────────────────────────
  #
  # The festival branch of metric_values_view maps each nomination to a code; for a few
  # orgs it's a hand-catalogued special (oscar_wins, cannes_palme_dor, …), otherwise the
  # ELSE branch emits `{lower(abbr)}_{win|nom}`. We catalogue exactly those emitted codes
  # (skipping the hand-curated ones) so every emitted festival code is normalized.
  # win_code/1 + nom_code/1 MUST mirror the view's CASE (catalog_contract_test enforces it).

  @hand_festival_codes ~w(oscar_wins oscar_nominations cannes_palme_dor venice_golden_lion berlin_golden_bear)
  @hand_canonical_codes ~w(1001_movies criterion national_film_registry sight_sound_critics_2022 afi_100 bfi_top_100)

  defp dynamic_festival_codes do
    hand = MapSet.new(@hand_festival_codes)

    "SELECT DISTINCT abbreviation FROM festival_organizations WHERE abbreviation IS NOT NULL"
    |> query_col()
    |> Enum.flat_map(fn abbr ->
      [
        {win_code(abbr), "won", "#{abbr} Win"},
        {nom_code(abbr), "nominated", "#{abbr} Nomination"}
      ]
      |> Enum.reject(fn {code, _field, _name} -> MapSet.member?(hand, code) end)
      |> Enum.map(fn {code, field, name} ->
        def_(%{
          code: code,
          name: name,
          source_table: "festival_nominations",
          source_type: abbr,
          source_field: field,
          normalization_type: "boolean",
          source_reliability: 0.8
        })
      end)
    end)
  end

  defp dynamic_list_codes do
    hand = MapSet.new(@hand_canonical_codes)

    "SELECT DISTINCT source_key FROM movie_lists WHERE source_key IS NOT NULL"
    |> query_col()
    |> Enum.reject(&MapSet.member?(hand, &1))
    |> Enum.map(fn key ->
      def_(%{
        code: key,
        name: key |> String.replace("_", " ") |> :string.titlecase(),
        source_table: "canonical_sources",
        source_type: key,
        source_field: "included",
        normalization_type: "boolean",
        source_reliability: 0.85
      })
    end)
  end

  # Mirror metric_values_view's festival CASE.
  defp win_code("AMPAS"), do: "oscar_wins"
  defp win_code("CANNES"), do: "cannes_palme_dor"
  defp win_code("VIFF"), do: "venice_golden_lion"
  defp win_code("BERLINALE"), do: "berlin_golden_bear"
  defp win_code(abbr), do: "#{String.downcase(abbr)}_win"

  defp nom_code("AMPAS"), do: "oscar_nominations"
  defp nom_code(abbr), do: "#{String.downcase(abbr)}_nom"

  # Single-column SQL → flat list; returns [] when the table is empty (e.g. test sandbox).
  defp query_col(sql), do: Repo.query!(sql, []).rows |> List.flatten()

  # Build a row with sensible defaults for the columns the seed always writes.
  defp def_(attrs) do
    Map.merge(
      %{
        description: nil,
        source_table: "external_metrics",
        source_type: nil,
        source_field: nil,
        category: nil,
        subcategory: nil,
        normalization_params: %{},
        raw_scale_min: nil,
        raw_scale_max: nil,
        active: true
      },
      attrs
    )
  end
end

defmodule Cinegraph.Metrics.ScoringService do
  @moduledoc """
  Service module for calculating movie scores using database-driven weight profiles.
  Replaces the hard-coded discovery scoring system with a flexible, database-backed approach.
  """

  import Ecto.Query, warn: false
  alias Cinegraph.Repo
  alias Cinegraph.Metrics.MetricWeightProfile
  alias Cinegraph.Movies.MovieScoreCache
  alias Cinegraph.Scoring.Lenses

  require Logger

  @default_category_weights Lenses.default_weights()

  @doc """
  Gets a weight profile by name from the database.
  Returns the profile or nil if not found.
  """
  def get_profile(name) when is_binary(name) do
    Repo.get_by(MetricWeightProfile, name: name, active: true)
  end

  def get_profile(name) when is_atom(name) do
    get_profile(normalize_profile_name(name))
  end

  @doc """
  Gets a weight profile by URL slug (e.g. "critics_choice" → "Critics Choice").
  """
  def get_profile_by_slug(slug) when is_binary(slug) do
    slug
    |> String.split("_")
    |> Enum.map_join(" ", &String.capitalize/1)
    |> get_profile()
  end

  @doc """
  Gets all active weight profiles from the database.
  """
  def get_all_profiles do
    from(p in MetricWeightProfile, where: p.active == true, order_by: [asc: p.name])
    |> Repo.all()
  end

  @doc """
  Gets the default weight profile from the database.
  """
  def get_default_profile do
    try do
      Repo.get_by(MetricWeightProfile, is_default: true, active: true) ||
        get_profile("Balanced")
    rescue
      e in [DBConnection.ConnectionError, Postgrex.Error, Ecto.QueryError] ->
        Logger.error("Failed to load default profile (DB error): #{inspect(e)}")
        fallback_profile()
    else
      nil ->
        # No default/Balanced rows found; use fallback to honor non-nil contract
        Logger.warning("No default or Balanced profile found, using fallback")
        fallback_profile()

      profile ->
        profile
    end
  end

  # Private helper to create consistent fallback profile
  defp fallback_profile do
    # Emit telemetry for ops visibility when fallback is used
    :telemetry.execute([:cinegraph, :scoring_service, :fallback_profile_used], %{count: 1}, %{})

    %MetricWeightProfile{
      name: "Fallback",
      description: "Emergency fallback profile",
      category_weights: @default_category_weights,
      weights: %{},
      active: true,
      is_default: true
    }
  end

  @doc """
  Converts a database weight profile to the format expected by the discovery UI.
  Maps category_weights to the six scoring lenses.

  Note:
  - "box_office" represents box office success (revenue, budget, ROI)
  - "auteurs" represents person quality scores (directors, actors, etc.)
  """
  def profile_to_discovery_weights(%MetricWeightProfile{} = profile) do
    %{
      mob: get_category_weight(profile, "mob", @default_category_weights["mob"]),
      critics: get_category_weight(profile, "critics", @default_category_weights["critics"]),
      festival_recognition:
        get_category_weight(
          profile,
          "festival_recognition",
          @default_category_weights["festival_recognition"]
        ),
      time_machine:
        get_category_weight(
          profile,
          "time_machine",
          @default_category_weights["time_machine"]
        ),
      auteurs:
        get_category_weight(
          profile,
          "auteurs",
          @default_category_weights["auteurs"]
        ),
      box_office:
        get_category_weight(
          profile,
          "box_office",
          @default_category_weights["box_office"]
        )
    }
  end

  @doc """
  Converts discovery UI weights back to database format for custom profiles.
  """
  def discovery_weights_to_profile(weights, name \\ "Custom") do
    %{
      name: name,
      description: "Custom weight profile created from discovery UI",
      category_weights: %{
        "mob" => Map.get(weights, :mob, @default_category_weights["mob"]),
        "critics" => Map.get(weights, :critics, @default_category_weights["critics"]),
        "festival_recognition" =>
          Map.get(
            weights,
            :festival_recognition,
            @default_category_weights["festival_recognition"]
          ),
        "box_office" =>
          Map.get(
            weights,
            :box_office,
            @default_category_weights["box_office"]
          ),
        "time_machine" =>
          Map.get(weights, :time_machine, @default_category_weights["time_machine"]),
        "auteurs" => Map.get(weights, :auteurs, @default_category_weights["auteurs"])
      },
      weights: build_metric_weights_from_discovery(weights),
      active: true,
      is_system: false
    }
  end

  @doc """
  Applies database-driven scoring to a movie query.
  This replaces the hard-coded scoring in DiscoveryScoringSimple.
  """
  def apply_scoring(query, profile_or_name, options \\ %{})

  def apply_scoring(query, %MetricWeightProfile{} = profile, options) do
    normalized_weights = profile |> profile_to_discovery_weights() |> normalize_weights()
    min_score = Map.get(options, :min_score, 0.0)

    # Single lens definition (#1036): score from the precomputed movie_score_caches rather
    # than re-deriving the lenses inline in SQL. LEFT join keeps movies without a cache row
    # (discovery_score 0), preserving the prior row set; order by the weighted lens sum.
    query
    |> cache_scored(normalized_weights)
    |> apply_min_score_filter(normalized_weights, min_score)
    |> order_by_cache_score(normalized_weights)
  end

  def apply_scoring(query, profile_name, options) when is_binary(profile_name) do
    case get_profile(profile_name) do
      nil -> apply_scoring(query, get_default_profile(), options)
      profile -> apply_scoring(query, profile, options)
    end
  end

  @doc """
  Fast path: applies discovery scoring by joining the precomputed `movie_score_caches`
  table instead of re-joining all source data. Returns movies ordered by the weighted
  sum of the 6 lens scores. Movies with no cache row are excluded (INNER JOIN).

  Use this for interactive/user-facing queries. Keep `apply_scoring/3` for offline
  computations or contexts where cache coverage may be incomplete.
  """
  def apply_scoring_from_cache(query, profile_or_name, options \\ %{})

  def apply_scoring_from_cache(query, %MetricWeightProfile{} = profile, options) do
    discovery_weights = profile_to_discovery_weights(profile)
    normalized = normalize_weights(discovery_weights)
    apply_cache_scoring(query, normalized, options)
  end

  def apply_scoring_from_cache(query, profile_name, options) when is_binary(profile_name) do
    case get_profile(profile_name) do
      nil -> apply_scoring_from_cache(query, get_default_profile(), options)
      profile -> apply_scoring_from_cache(query, profile, options)
    end
  end

  defp apply_cache_scoring(query, weights, options) do
    min_score = Map.get(options, :min_score, 0.0)
    mob = Map.get(weights, :mob, 0.0)
    critics = Map.get(weights, :critics, 0.0)
    festival = Map.get(weights, :festival_recognition, 0.0)
    time_m = Map.get(weights, :time_machine, 0.0)
    auteurs = Map.get(weights, :auteurs, 0.0)
    box_office = Map.get(weights, :box_office, 0.0)

    from m in query,
      join: sc in MovieScoreCache,
      on: sc.movie_id == m.id,
      as: :score_cache,
      where: sc.overall_score >= ^min_score,
      order_by: [
        desc_nulls_last:
          fragment(
            "?::float * COALESCE(?, 0) + ?::float * COALESCE(?, 0) + ?::float * COALESCE(?, 0) + ?::float * COALESCE(?, 0) + ?::float * COALESCE(?, 0) + ?::float * COALESCE(?, 0)",
            ^mob,
            sc.mob_score,
            ^critics,
            sc.critics_score,
            ^festival,
            sc.festival_recognition_score,
            ^time_m,
            sc.time_machine_score,
            ^auteurs,
            sc.auteurs_score,
            ^box_office,
            sc.box_office_score
          )
      ],
      select: m
  end

  @doc """
  Adds discovery scores to a query for display purposes without affecting sorting.
  Used when we want movie cards to show scores but preserve custom sorting.
  """
  def add_scores_for_display(query, profile_or_name)

  def add_scores_for_display(query, %MetricWeightProfile{} = profile) do
    normalized_weights = profile |> profile_to_discovery_weights() |> normalize_weights()

    # Adds discovery_score + score_components from the cache; no ordering/filtering.
    cache_scored(query, normalized_weights)
  end

  def add_scores_for_display(query, profile_name) when is_binary(profile_name) do
    case get_profile(profile_name) do
      nil -> add_scores_for_display(query, get_default_profile())
      profile -> add_scores_for_display(query, profile)
    end
  end

  @doc """
  Normalizes a profile name from atom or string format to title case.
  """
  def normalize_profile_name(name) when is_atom(name) do
    name |> Atom.to_string() |> normalize_profile_name()
  end

  def normalize_profile_name(name) when is_binary(name) do
    name
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map(&String.capitalize/1)
    |> Enum.join(" ")
  end

  # Private functions

  defp get_category_weight(%MetricWeightProfile{category_weights: weights}, category, default) do
    value = Map.get(weights || %{}, category, default)
    # Ensure we always return a number
    case value do
      nil -> default
      v when is_number(v) -> v
      _ -> default
    end
  end

  # Note: SQL fragment extraction isn't feasible with Ecto's query compilation
  # The discovery score calculation is kept inline in each context for now

  defp build_metric_weights_from_discovery(weights) do
    mob_weight = Map.get(weights, :mob, 0.2)
    critics_weight = Map.get(weights, :critics, 0.2)
    award_weight = Map.get(weights, :festival_recognition, 0.2)
    cultural_weight = Map.get(weights, :time_machine, 0.2)

    %{
      # Mob (audience) metrics
      "imdb_rating" => mob_weight * 1.0,
      "tmdb_rating" => mob_weight * 1.0,
      "imdb_rating_votes" => mob_weight * 0.5,
      # Critics metrics
      "metacritic_metascore" => critics_weight * 1.0,
      "rotten_tomatoes_tomatometer" => critics_weight * 1.0,

      # Industry Recognition metrics
      "oscar_wins" => award_weight * 3,
      "oscar_nominations" => award_weight * 2,
      "cannes_palme_dor" => award_weight * 2,
      "venice_golden_lion" => award_weight * 2,
      "berlin_golden_bear" => award_weight * 2,

      # Cultural Impact metrics
      "1001_movies" => cultural_weight * 2,
      "criterion" => cultural_weight * 2,
      "sight_sound_critics_2022" => cultural_weight * 1.5,
      "national_film_registry" => cultural_weight * 1.5
    }
  end

  defp normalize_weights(weights) do
    total = Enum.sum(Map.values(weights))

    if total == 0 do
      Lenses.default_atom_weights()
    else
      Map.new(weights, fn {k, v} -> {k, v / total} end)
    end
  end

  # ── cache-backed scoring (the single lens definition, #1036) ───────────────
  # Merges discovery_score (weighted sum of the 6 cached lens scores) and
  # score_components (the 6 cached lens scores as a map) onto each movie, from the
  # precomputed movie_score_caches. LEFT join so uncached movies survive (score 0).

  defp cache_scored(query, weights) do
    {mob, critics, festival, time_m, auteurs, box_office} = lens_weight_tuple(weights)

    from m in query,
      left_join: sc in MovieScoreCache,
      on: sc.movie_id == m.id,
      as: :score_cache,
      select_merge: %{
        discovery_score:
          fragment(
            "COALESCE(?::float * COALESCE(?, 0) + ?::float * COALESCE(?, 0) + ?::float * COALESCE(?, 0) + ?::float * COALESCE(?, 0) + ?::float * COALESCE(?, 0) + ?::float * COALESCE(?, 0), 0)",
            ^mob,
            sc.mob_score,
            ^critics,
            sc.critics_score,
            ^festival,
            sc.festival_recognition_score,
            ^time_m,
            sc.time_machine_score,
            ^auteurs,
            sc.auteurs_score,
            ^box_office,
            sc.box_office_score
          ),
        score_components:
          fragment(
            "jsonb_build_object('mob', ?, 'critics', ?, 'festival_recognition', ?, 'time_machine', ?, 'auteurs', ?, 'box_office', ?)",
            sc.mob_score,
            sc.critics_score,
            sc.festival_recognition_score,
            sc.time_machine_score,
            sc.auteurs_score,
            sc.box_office_score
          )
      }
  end

  defp order_by_cache_score(query, weights) do
    {mob, critics, festival, time_m, auteurs, box_office} = lens_weight_tuple(weights)

    order_by(query, [m, score_cache: sc],
      desc_nulls_last:
        fragment(
          "?::float * COALESCE(?, 0) + ?::float * COALESCE(?, 0) + ?::float * COALESCE(?, 0) + ?::float * COALESCE(?, 0) + ?::float * COALESCE(?, 0) + ?::float * COALESCE(?, 0)",
          ^mob,
          sc.mob_score,
          ^critics,
          sc.critics_score,
          ^festival,
          sc.festival_recognition_score,
          ^time_m,
          sc.time_machine_score,
          ^auteurs,
          sc.auteurs_score,
          ^box_office,
          sc.box_office_score
        )
    )
  end

  # Filter on the SAME profile-weighted sum used for ordering/display — not overall_score
  # (which is the fixed editorial-weighted cache value and would mis-threshold non-balanced
  # profiles).
  defp apply_min_score_filter(query, weights, min_score)
       when is_number(min_score) and min_score > 0 do
    {mob, critics, festival, time_m, auteurs, box_office} = lens_weight_tuple(weights)

    where(
      query,
      [m, score_cache: sc],
      fragment(
        "(?::float * COALESCE(?, 0) + ?::float * COALESCE(?, 0) + ?::float * COALESCE(?, 0) + ?::float * COALESCE(?, 0) + ?::float * COALESCE(?, 0) + ?::float * COALESCE(?, 0)) >= ?",
        ^mob,
        sc.mob_score,
        ^critics,
        sc.critics_score,
        ^festival,
        sc.festival_recognition_score,
        ^time_m,
        sc.time_machine_score,
        ^auteurs,
        sc.auteurs_score,
        ^box_office,
        sc.box_office_score,
        ^min_score
      )
    )
  end

  defp apply_min_score_filter(query, _weights, _min_score), do: query

  defp lens_weight_tuple(weights) do
    {
      Map.get(weights, :mob, 0.0),
      Map.get(weights, :critics, 0.0),
      Map.get(weights, :festival_recognition, 0.0),
      Map.get(weights, :time_machine, 0.0),
      Map.get(weights, :auteurs, 0.0),
      Map.get(weights, :box_office, 0.0)
    }
  end
end

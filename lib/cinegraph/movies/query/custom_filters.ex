defmodule Cinegraph.Movies.Query.CustomFilters do
  @moduledoc """
  Custom filters for complex queries that Flop doesn't handle natively.
  Each function takes a query and params, returns an updated query.
  """

  import Ecto.Query
  alias Cinegraph.Movies.Query.Params

  def apply_all(query, %Params{} = params) do
    query
    |> filter_by_genres(params.genres)
    |> filter_by_countries(params.countries)
    |> filter_by_languages(params.languages)
    |> filter_by_lists(params.lists)
    |> filter_by_year(params)
    |> filter_by_decade(params.decade)
    |> filter_by_runtime(params)
    |> filter_by_rating(params.rating_min)
    |> filter_by_awards(params)
    |> filter_by_rating_preset(params.rating_preset)
    |> filter_by_discovery_preset(params.discovery_preset)
    |> filter_by_award_preset(params.award_preset)
    |> filter_by_people(params)
    |> filter_by_metric_thresholds(params)
    |> apply_distinct_if_needed()
  end

  # Genre filtering (OR logic - movie must have ANY of the selected genres)
  defp filter_by_genres(query, []), do: query
  defp filter_by_genres(query, nil), do: query
  defp filter_by_genres(query, genre_ids) do
    query
    |> join(:inner, [m], mg in "movie_genres", on: mg.movie_id == m.id)
    |> where([m, mg], mg.genre_id in ^genre_ids)
    |> group_by([m], m.id)
  end

  # Country filtering
  defp filter_by_countries(query, []), do: query
  defp filter_by_countries(query, nil), do: query
  defp filter_by_countries(query, country_ids) do
    query
    |> join(:inner, [m, ...], mpc in "movie_production_countries", on: mpc.movie_id == m.id)
    |> where([m, ..., mpc], mpc.production_country_id in ^country_ids)
  end

  # Language filtering
  defp filter_by_languages(query, []), do: query
  defp filter_by_languages(query, nil), do: query
  defp filter_by_languages(query, language_codes) do
    where(query, [m], m.original_language in ^language_codes)
  end

  # Canonical list filtering
  defp filter_by_lists(query, []), do: query
  defp filter_by_lists(query, nil), do: query
  defp filter_by_lists(query, list_keys) do
    # Build dynamic OR condition for multiple lists
    conditions = Enum.reduce(list_keys, false, fn list_key, acc ->
      condition = dynamic([m], fragment("? \\? ?", m.canonical_sources, ^list_key))
      
      if acc == false do
        condition
      else
        dynamic([m], ^acc or ^condition)
      end
    end)
    
    if conditions == false do
      query
    else
      where(query, ^conditions)
    end
  end

  # Year filtering
  defp filter_by_year(query, %{year: nil, year_from: nil, year_to: nil}), do: query
  defp filter_by_year(query, %{year: year}) when not is_nil(year) do
    where(query, [m], fragment("EXTRACT(YEAR FROM ?) = ?", m.release_date, ^year))
  end
  defp filter_by_year(query, %{year_from: from_year, year_to: to_year}) do
    query = if from_year do
      from_date = Date.new!(from_year, 1, 1)
      where(query, [m], m.release_date >= ^from_date)
    else
      query
    end
    
    if to_year do
      to_date = Date.new!(to_year, 12, 31)
      where(query, [m], m.release_date <= ^to_date)
    else
      query
    end
  end

  # Decade filtering
  defp filter_by_decade(query, nil), do: query
  defp filter_by_decade(query, decade) do
    from_date = Date.new!(decade, 1, 1)
    to_date = Date.new!(decade + 9, 12, 31)
    where(query, [m], m.release_date >= ^from_date and m.release_date <= ^to_date)
  end

  # Runtime filtering
  defp filter_by_runtime(query, %{runtime_min: nil, runtime_max: nil}), do: query
  defp filter_by_runtime(query, %{runtime_min: min, runtime_max: max}) do
    query = if min, do: where(query, [m], m.runtime >= ^min), else: query
    if max, do: where(query, [m], m.runtime <= ^max), else: query
  end

  # Basic rating filter
  defp filter_by_rating(query, nil), do: query
  defp filter_by_rating(query, min_rating) do
    query
    |> join(:inner, [m, ...], em in "external_metrics",
      on: em.movie_id == m.id and em.source == "tmdb" and em.metric_type == "rating_average"
    )
    |> where([m, ..., em], em.value >= ^min_rating)
  end

  # Award filtering
  defp filter_by_awards(query, params) do
    query
    |> filter_by_award_status(params.award_status)
    |> filter_by_festival(params.festivals || params.festival_id)
    |> filter_by_award_category(params.award_category_id)
    |> filter_by_award_years(params.award_year_from, params.award_year_to)
  end

  defp filter_by_award_status(query, nil), do: query
  defp filter_by_award_status(query, "any_nomination") do
    join(query, :inner, [m], nom in "festival_nominations", on: nom.movie_id == m.id)
  end
  defp filter_by_award_status(query, "won") do
    join(query, :inner, [m], nom in "festival_nominations",
      on: nom.movie_id == m.id and nom.won == true
    )
  end
  defp filter_by_award_status(query, "nominated_only") do
    join(query, :inner, [m], nom in "festival_nominations",
      on: nom.movie_id == m.id and nom.won == false
    )
  end
  defp filter_by_award_status(query, "multiple_awards") do
    query
    |> join(:inner, [m], nom in "festival_nominations",
      on: nom.movie_id == m.id and nom.won == true
    )
    |> group_by([m], m.id)
    |> having([m, nom], count(nom.id) > 1)
  end
  defp filter_by_award_status(query, _), do: query

  defp filter_by_festival(query, nil), do: query
  defp filter_by_festival(query, []), do: query
  defp filter_by_festival(query, festival_ids) when is_list(festival_ids) do
    query
    |> join(:inner, [m, ...], nom in "festival_nominations", on: nom.movie_id == m.id)
    |> join(:inner, [..., nom], fc in "festival_ceremonies", on: fc.id == nom.ceremony_id)
    |> where([..., fc], fc.organization_id in ^festival_ids)
  end
  defp filter_by_festival(query, festival_id) do
    # Single festival ID for backwards compatibility
    filter_by_festival(query, [festival_id])
  end

  defp filter_by_award_category(query, nil), do: query
  defp filter_by_award_category(query, category_id) do
    query
    |> join(:inner, [m, ...], nom in "festival_nominations", on: nom.movie_id == m.id)
    |> where([..., nom], nom.category_id == ^category_id)
  end

  defp filter_by_award_years(query, nil, nil), do: query
  defp filter_by_award_years(query, from_year, to_year) do
    query = if from_year do
      query
      |> join(:inner, [m, ...], nom in "festival_nominations", on: nom.movie_id == m.id)
      |> join(:inner, [..., nom], fc in "festival_ceremonies", on: fc.id == nom.ceremony_id)
      |> where([..., fc], fc.year >= ^from_year)
    else
      query
    end
    
    if to_year do
      query
      |> join(:inner, [m, ...], nom in "festival_nominations", on: nom.movie_id == m.id)
      |> join(:inner, [..., nom], fc in "festival_ceremonies", on: fc.id == nom.ceremony_id)
      |> where([..., fc], fc.year <= ^to_year)
    else
      query
    end
  end

  # Rating preset filters
  defp filter_by_rating_preset(query, nil), do: query
  defp filter_by_rating_preset(query, "highly_rated") do
    # Movies with average TMDb/IMDb rating >= 7.5
    query
    |> join(:left, [m], tmdb in "external_metrics", as: :tmdb_rating,
      on: tmdb.movie_id == m.id and tmdb.source == "tmdb" and tmdb.metric_type == "rating_average"
    )
    |> join(:left, [m], imdb in "external_metrics", as: :imdb_rating,
      on: imdb.movie_id == m.id and imdb.source == "imdb" and imdb.metric_type == "rating_average"
    )
    |> where([tmdb_rating: tmdb, imdb_rating: imdb],
      fragment("(COALESCE(?, 0) + COALESCE(?, 0)) / 2 >= 7.5", tmdb.value, imdb.value)
    )
  end
  defp filter_by_rating_preset(query, "well_reviewed") do
    # Movies with average TMDb/IMDb rating >= 6.0
    query
    |> join(:left, [m], tmdb in "external_metrics", as: :tmdb_rating,
      on: tmdb.movie_id == m.id and tmdb.source == "tmdb" and tmdb.metric_type == "rating_average"
    )
    |> join(:left, [m], imdb in "external_metrics", as: :imdb_rating,
      on: imdb.movie_id == m.id and imdb.source == "imdb" and imdb.metric_type == "rating_average"
    )
    |> where([tmdb_rating: tmdb, imdb_rating: imdb],
      fragment("(COALESCE(?, 0) + COALESCE(?, 0)) / 2 >= 6.0", tmdb.value, imdb.value)
    )
  end
  defp filter_by_rating_preset(query, "critically_acclaimed") do
    # Movies with high Metacritic (>= 70) or high RT Critics (>= 80)
    query
    |> join(:left, [m], mc in "external_metrics", as: :mc_rating,
      on: mc.movie_id == m.id and mc.source == "metacritic" and mc.metric_type == "metascore"
    )
    |> join(:left, [m], rt in "external_metrics", as: :rt_rating,
      on: rt.movie_id == m.id and rt.source == "rotten_tomatoes" and rt.metric_type == "tomatometer"
    )
    |> where([mc_rating: mc, rt_rating: rt],
      fragment("COALESCE(?, 0) >= 70 OR COALESCE(?, 0) >= 80", mc.value, rt.value)
    )
  end
  defp filter_by_rating_preset(query, _), do: query

  # Discovery preset filters
  defp filter_by_discovery_preset(query, nil), do: query
  defp filter_by_discovery_preset(query, "award_winners") do
    join(query, :inner, [m], nom in "festival_nominations",
      on: nom.movie_id == m.id and nom.won == true
    )
  end
  defp filter_by_discovery_preset(query, "popular_favorites") do
    # High popular opinion score (>= 0.7)
    query
    |> join(:left, [m], tmdb in "external_metrics", as: :tmdb_pop,
      on: tmdb.movie_id == m.id and tmdb.source == "tmdb" and tmdb.metric_type == "rating_average"
    )
    |> join(:left, [m], imdb in "external_metrics", as: :imdb_pop,
      on: imdb.movie_id == m.id and imdb.source == "imdb" and imdb.metric_type == "rating_average"
    )
    |> where([tmdb_pop: tmdb, imdb_pop: imdb],
      fragment(
        "(COALESCE(?, 0) / 10.0 * 0.5 + COALESCE(?, 0) / 10.0 * 0.5) >= 0.7",
        tmdb.value,
        imdb.value
      )
    )
  end
  defp filter_by_discovery_preset(query, "hidden_gems") do
    # High rating but low votes
    query
    |> join(:left, [m], tmdb_rating in "external_metrics", as: :tmdb_gem_rating,
      on: tmdb_rating.movie_id == m.id and tmdb_rating.source == "tmdb" and 
          tmdb_rating.metric_type == "rating_average"
    )
    |> join(:left, [m], tmdb_votes in "external_metrics", as: :tmdb_gem_votes,
      on: tmdb_votes.movie_id == m.id and tmdb_votes.source == "tmdb" and 
          tmdb_votes.metric_type == "rating_votes"
    )
    |> where([tmdb_gem_rating: tmdb_rating, tmdb_gem_votes: tmdb_votes],
      fragment(
        "COALESCE(?, 0) >= 7.0 AND COALESCE(?, 0) < 10000",
        tmdb_rating.value,
        tmdb_votes.value
      )
    )
  end
  defp filter_by_discovery_preset(query, _), do: query

  # Award preset filters
  defp filter_by_award_preset(query, nil), do: query
  defp filter_by_award_preset(query, "recent_awards") do
    query
    |> join(:inner, [m], nom in "festival_nominations", on: nom.movie_id == m.id)
    |> join(:inner, [..., nom], fc in "festival_ceremonies", on: fc.id == nom.ceremony_id)
    |> where([..., fc], fc.year >= 2020)
  end
  defp filter_by_award_preset(query, "2010s") do
    query
    |> join(:inner, [m], nom in "festival_nominations", on: nom.movie_id == m.id)
    |> join(:inner, [..., nom], fc in "festival_ceremonies", on: fc.id == nom.ceremony_id)
    |> where([..., fc], fc.year >= 2010 and fc.year <= 2019)
  end
  defp filter_by_award_preset(query, "2000s") do
    query
    |> join(:inner, [m], nom in "festival_nominations", on: nom.movie_id == m.id)
    |> join(:inner, [..., nom], fc in "festival_ceremonies", on: fc.id == nom.ceremony_id)
    |> where([..., fc], fc.year >= 2000 and fc.year <= 2009)
  end
  defp filter_by_award_preset(query, "classic") do
    query
    |> join(:inner, [m], nom in "festival_nominations", on: nom.movie_id == m.id)
    |> join(:inner, [..., nom], fc in "festival_ceremonies", on: fc.id == nom.ceremony_id)
    |> where([..., fc], fc.year < 2000)
  end
  defp filter_by_award_preset(query, _), do: query

  # People filtering
  defp filter_by_people(query, %{people_ids: [], people_role: _}), do: query
  defp filter_by_people(query, %{people_ids: nil, people_role: _}), do: query
  defp filter_by_people(query, %{people_ids: people_ids, people_role: role}) do
    query = join(query, :inner, [m], mc in "movie_credits", on: mc.movie_id == m.id, as: :credits)
    
    case role do
      "director" ->
        where(query, [credits: mc], mc.person_id in ^people_ids and mc.job == "Director")
      
      "cast" ->
        where(query, [credits: mc], mc.person_id in ^people_ids and mc.credit_type == "cast")
      
      "writer" ->
        where(query, [credits: mc], mc.person_id in ^people_ids and 
          mc.job in ["Writer", "Screenplay", "Story", "Novel", "Characters", "Teleplay", "Adaptation"])
      
      "producer" ->
        where(query, [credits: mc], mc.person_id in ^people_ids and 
          mc.job in ["Producer", "Executive Producer", "Associate Producer", "Co-Producer", "Line Producer"])
      
      "cinematographer" ->
        where(query, [credits: mc], mc.person_id in ^people_ids and 
          mc.job in ["Director of Photography", "Cinematography", "Cinematographer"])
      
      "composer" ->
        where(query, [credits: mc], mc.person_id in ^people_ids and 
          mc.job in ["Original Music Composer", "Composer", "Music", "Music Score"])
      
      "editor" ->
        where(query, [credits: mc], mc.person_id in ^people_ids and 
          mc.job in ["Editor", "Film Editor", "Editorial", "Editing"])
      
      _ ->
        where(query, [credits: mc], mc.person_id in ^people_ids)
    end
  end

  # Metric threshold filters
  defp filter_by_metric_thresholds(query, params) do
    query
    |> filter_by_metric(:popular_opinion, params.popular_opinion_min)
    |> filter_by_metric(:critical_acclaim, params.critical_acclaim_min)
    |> filter_by_metric(:industry_recognition, params.industry_recognition_min)
    |> filter_by_metric(:cultural_impact, params.cultural_impact_min)
    |> filter_by_metric(:people_quality, params.people_quality_min)
  end

  defp filter_by_metric(query, _dimension, nil), do: query
  defp filter_by_metric(query, :popular_opinion, min_value) do
    where(query, [m],
      fragment(
        """
        COALESCE((
          SELECT (COALESCE(tr.value, 0) / 10.0 * 0.5 + COALESCE(ir.value, 0) / 10.0 * 0.5)
          FROM (SELECT value FROM external_metrics WHERE movie_id = ? AND source = 'tmdb' AND metric_type = 'rating_average' LIMIT 1) tr,
               (SELECT value FROM external_metrics WHERE movie_id = ? AND source = 'imdb' AND metric_type = 'rating_average' LIMIT 1) ir
        ), 0) >= ?
        """,
        m.id,
        m.id,
        ^min_value
      )
    )
  end
  defp filter_by_metric(query, :critical_acclaim, min_value) do
    where(query, [m],
      fragment(
        """
        COALESCE((
          SELECT (COALESCE(mc.value, 0) / 100.0 * 0.5 + COALESCE(rt.value, 0) / 100.0 * 0.5)
          FROM (SELECT value FROM external_metrics WHERE movie_id = ? AND source = 'metacritic' AND metric_type = 'metascore' LIMIT 1) mc,
               (SELECT value FROM external_metrics WHERE movie_id = ? AND source = 'rotten_tomatoes' AND metric_type = 'tomatometer' LIMIT 1) rt
        ), 0) >= ?
        """,
        m.id,
        m.id,
        ^min_value
      )
    )
  end
  defp filter_by_metric(query, :industry_recognition, min_value) do
    where(query, [m],
      fragment(
        """
        COALESCE((
          SELECT LEAST(1.0, (COALESCE(f.wins, 0) * 0.2 + COALESCE(f.nominations, 0) * 0.05))
          FROM (
            SELECT COUNT(CASE WHEN won = true THEN 1 END) as wins,
                   COUNT(*) as nominations
            FROM festival_nominations
            WHERE movie_id = ?
          ) f
        ), 0) >= ?
        """,
        m.id,
        ^min_value
      )
    )
  end
  defp filter_by_metric(query, :cultural_impact, min_value) do
    where(query, [m],
      fragment(
        """
        COALESCE(
          LEAST(1.0, 
            COALESCE(
              (SELECT COUNT(*) * 0.1
               FROM jsonb_each(COALESCE(?, '{}'::jsonb))), 
              0
            ) + 
            COALESCE(
              (SELECT CASE 
                WHEN value IS NULL OR value = 0 THEN 0
                ELSE LN(value + 1) / LN(1001)
              END
              FROM external_metrics 
              WHERE movie_id = ? 
                AND source = 'tmdb' 
                AND metric_type = 'popularity_score' 
              LIMIT 1), 
              0
            )
          ), 
          0
        ) >= ?
        """,
        m.canonical_sources,
        m.id,
        ^min_value
      )
    )
  end
  defp filter_by_metric(query, :people_quality, min_value) do
    where(query, [m],
      fragment(
        """
        COALESCE((
          SELECT AVG(DISTINCT pm.score) / 100.0
          FROM person_metrics pm
          JOIN movie_credits mc ON pm.person_id = mc.person_id
          WHERE mc.movie_id = ? AND pm.metric_type = 'quality_score'
        ), 0) >= ?
        """,
        m.id,
        ^min_value
      )
    )
  end

  defp apply_distinct_if_needed(query) do
    # For queries with GROUP BY (like genre filtering), don't add DISTINCT 
    # as it can interfere with Flop's count calculation
    if has_group_by?(query) do
      query
    else
      # Apply distinct if the query has joins to avoid duplicate rows
      if has_joins?(query) do
        distinct(query, true)
      else
        query
      end
    end
  end

  defp has_joins?(%Ecto.Query{joins: joins}) when length(joins) > 0, do: true
  defp has_joins?(_), do: false
  
  defp has_group_by?(%Ecto.Query{group_bys: group_bys}) when length(group_bys) > 0, do: true
  defp has_group_by?(_), do: false
end
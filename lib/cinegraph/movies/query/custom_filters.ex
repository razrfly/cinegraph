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
    subq =
      from(mpc in "movie_production_countries",
        select: mpc.movie_id,
        where: mpc.production_country_id in ^country_ids
      )

    where(query, [m], m.id in subquery(subq))
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
    conditions =
      Enum.reduce(list_keys, false, fn list_key, acc ->
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
    query =
      if from_year do
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
    where(
      query,
      [m],
      fragment(
        "(SELECT value FROM external_metrics WHERE movie_id = ? AND source = 'tmdb' AND metric_type = 'rating_average' ORDER BY fetched_at DESC LIMIT 1) >= ?",
        m.id,
        ^min_rating
      )
    )
  end

  # Award filtering - uses subquery approach for better performance
  # This avoids multiple joins to the same tables and reduces the need for DISTINCT
  defp filter_by_awards(query, params) do
    festival_ids = params.festivals || params.festival_id
    award_status = params.award_status
    category_id = params.award_category_id
    year_from = params.award_year_from
    year_to = params.award_year_to

    # If no award filters, return query unchanged
    # Note: festival_ids defaults to [] (empty list), so check for both nil and empty
    if is_nil(award_status) and (is_nil(festival_ids) or festival_ids == []) and
         is_nil(category_id) and is_nil(year_from) and is_nil(year_to) do
      query
    else
      # Build a subquery to get movie IDs matching award criteria
      # This is much more efficient than multiple joins on the main query
      movie_ids_subquery =
        build_award_movie_ids_subquery(
          award_status,
          normalize_festival_ids(festival_ids),
          category_id,
          year_from,
          year_to
        )

      where(query, [m], m.id in subquery(movie_ids_subquery))
    end
  end

  defp normalize_festival_ids(nil), do: nil
  defp normalize_festival_ids([]), do: nil
  defp normalize_festival_ids(ids) when is_list(ids), do: ids
  defp normalize_festival_ids(id), do: [id]

  # Build a subquery that returns movie_ids matching all award criteria
  defp build_award_movie_ids_subquery(award_status, festival_ids, category_id, year_from, year_to) do
    # Start with festival_nominations to get movie_ids
    base = from(nom in "festival_nominations", select: nom.movie_id)

    # Apply award status filter
    base = apply_award_status_to_subquery(base, award_status)

    # Apply category filter
    base = apply_category_to_subquery(base, category_id)

    # Apply festival and year filters (these require ceremony join)
    apply_festival_and_years_to_subquery(base, festival_ids, year_from, year_to)
  end

  defp apply_award_status_to_subquery(query, nil), do: query
  defp apply_award_status_to_subquery(query, "any_nomination"), do: query

  defp apply_award_status_to_subquery(query, "won") do
    where(query, [nom], nom.won == true)
  end

  defp apply_award_status_to_subquery(query, "nominated_only") do
    where(query, [nom], nom.won == false)
  end

  defp apply_award_status_to_subquery(query, "multiple_awards") do
    query
    |> where([nom], nom.won == true)
    |> group_by([nom], nom.movie_id)
    |> having([nom], count(nom.id) > 1)
  end

  defp apply_award_status_to_subquery(query, _), do: query

  defp apply_category_to_subquery(query, nil), do: query

  defp apply_category_to_subquery(query, category_id) do
    where(query, [nom], nom.category_id == ^category_id)
  end

  defp apply_festival_and_years_to_subquery(query, nil, nil, nil), do: query

  defp apply_festival_and_years_to_subquery(query, festival_ids, year_from, year_to) do
    # Join to ceremonies only if we need festival or year filtering
    query = join(query, :inner, [nom], fc in "festival_ceremonies", on: fc.id == nom.ceremony_id)

    # Apply festival filter
    query =
      if festival_ids do
        where(query, [..., fc], fc.organization_id in ^festival_ids)
      else
        query
      end

    # Apply year filters
    query =
      if year_from do
        where(query, [..., fc], fc.year >= ^year_from)
      else
        query
      end

    if year_to do
      where(query, [..., fc], fc.year <= ^year_to)
    else
      query
    end
  end

  # Rating preset filters
  defp filter_by_rating_preset(query, nil), do: query

  defp filter_by_rating_preset(query, "highly_rated") do
    # Movies with average TMDb/IMDb rating >= 7.5
    # Using subquery approach to avoid DISTINCT/ORDER BY conflicts
    where(
      query,
      [m],
      fragment(
        """
        (
          COALESCE(
            (SELECT value FROM external_metrics
             WHERE movie_id = ? AND source = 'tmdb' AND metric_type = 'rating_average'
             ORDER BY fetched_at DESC LIMIT 1), 0
          ) +
          COALESCE(
            (SELECT value FROM external_metrics
             WHERE movie_id = ? AND source = 'imdb' AND metric_type = 'rating_average'
             ORDER BY fetched_at DESC LIMIT 1), 0
          )
        ) / 2 >= 7.5
        """,
        m.id,
        m.id
      )
    )
  end

  defp filter_by_rating_preset(query, "well_reviewed") do
    # Movies with average TMDb/IMDb rating >= 6.0
    # Using subquery approach to avoid DISTINCT/ORDER BY conflicts
    where(
      query,
      [m],
      fragment(
        """
        (
          COALESCE(
            (SELECT value FROM external_metrics
             WHERE movie_id = ? AND source = 'tmdb' AND metric_type = 'rating_average'
             ORDER BY fetched_at DESC LIMIT 1), 0
          ) +
          COALESCE(
            (SELECT value FROM external_metrics
             WHERE movie_id = ? AND source = 'imdb' AND metric_type = 'rating_average'
             ORDER BY fetched_at DESC LIMIT 1), 0
          )
        ) / 2 >= 6.0
        """,
        m.id,
        m.id
      )
    )
  end

  defp filter_by_rating_preset(query, "critically_acclaimed") do
    # Movies with high Metacritic (>= 70) or high RT Critics (>= 80)
    # Using subquery approach to avoid DISTINCT/ORDER BY conflicts
    where(
      query,
      [m],
      fragment(
        """
        COALESCE(
          (SELECT value FROM external_metrics
           WHERE movie_id = ? AND source = 'metacritic' AND metric_type = 'metascore'
           ORDER BY fetched_at DESC LIMIT 1), 0
        ) >= 70
        OR
        COALESCE(
          (SELECT value FROM external_metrics
           WHERE movie_id = ? AND source = 'rotten_tomatoes' AND metric_type = 'tomatometer'
           ORDER BY fetched_at DESC LIMIT 1), 0
        ) >= 80
        """,
        m.id,
        m.id
      )
    )
  end

  defp filter_by_rating_preset(query, _), do: query

  # Discovery preset filters
  defp filter_by_discovery_preset(query, nil), do: query

  defp filter_by_discovery_preset(query, "award_winners") do
    # Use subquery for better performance - avoids DISTINCT requirement
    subq =
      from(nom in "festival_nominations",
        where: nom.won == true,
        select: nom.movie_id
      )

    where(query, [m], m.id in subquery(subq))
  end

  defp filter_by_discovery_preset(query, "popular_favorites") do
    # High popular opinion score (>= 0.7)
    # Using subquery approach to avoid DISTINCT/ORDER BY conflicts
    where(
      query,
      [m],
      fragment(
        """
        (
          COALESCE(
            (SELECT value FROM external_metrics
             WHERE movie_id = ? AND source = 'tmdb' AND metric_type = 'rating_average'
             ORDER BY fetched_at DESC LIMIT 1), 0
          ) / 10.0 * 0.5
          +
          COALESCE(
            (SELECT value FROM external_metrics
             WHERE movie_id = ? AND source = 'imdb' AND metric_type = 'rating_average'
             ORDER BY fetched_at DESC LIMIT 1), 0
          ) / 10.0 * 0.5
        ) >= 0.7
        """,
        m.id,
        m.id
      )
    )
  end

  defp filter_by_discovery_preset(query, "hidden_gems") do
    # High rating but low votes
    # Using subquery approach to avoid DISTINCT/ORDER BY conflicts
    where(
      query,
      [m],
      fragment(
        """
        COALESCE(
          (SELECT value FROM external_metrics
           WHERE movie_id = ? AND source = 'tmdb' AND metric_type = 'rating_average'
           ORDER BY fetched_at DESC LIMIT 1), 0
        ) >= 7.0
        AND
        COALESCE(
          (SELECT value FROM external_metrics
           WHERE movie_id = ? AND source = 'tmdb' AND metric_type = 'rating_votes'
           ORDER BY fetched_at DESC LIMIT 1), 0
        ) < 10000
        """,
        m.id,
        m.id
      )
    )
  end

  defp filter_by_discovery_preset(query, _), do: query

  # Award preset filters - use subquery approach for better performance
  defp filter_by_award_preset(query, nil), do: query

  defp filter_by_award_preset(query, "recent_awards") do
    subq =
      from(nom in "festival_nominations",
        join: fc in "festival_ceremonies",
        on: fc.id == nom.ceremony_id,
        where: fc.year >= 2020,
        select: nom.movie_id
      )

    where(query, [m], m.id in subquery(subq))
  end

  defp filter_by_award_preset(query, "2010s") do
    subq =
      from(nom in "festival_nominations",
        join: fc in "festival_ceremonies",
        on: fc.id == nom.ceremony_id,
        where: fc.year >= 2010 and fc.year <= 2019,
        select: nom.movie_id
      )

    where(query, [m], m.id in subquery(subq))
  end

  defp filter_by_award_preset(query, "2000s") do
    subq =
      from(nom in "festival_nominations",
        join: fc in "festival_ceremonies",
        on: fc.id == nom.ceremony_id,
        where: fc.year >= 2000 and fc.year <= 2009,
        select: nom.movie_id
      )

    where(query, [m], m.id in subquery(subq))
  end

  defp filter_by_award_preset(query, "classic") do
    subq =
      from(nom in "festival_nominations",
        join: fc in "festival_ceremonies",
        on: fc.id == nom.ceremony_id,
        where: fc.year < 2000,
        select: nom.movie_id
      )

    where(query, [m], m.id in subquery(subq))
  end

  defp filter_by_award_preset(query, _), do: query

  # People filtering
  defp filter_by_people(query, %{people_ids: [], people_role: _}), do: query
  defp filter_by_people(query, %{people_ids: nil, people_role: _}), do: query

  defp filter_by_people(query, %{people_ids: people_ids, people_role: role}) do
    subq = build_people_subquery(people_ids, role)
    where(query, [m], m.id in subquery(subq))
  end

  defp build_people_subquery(people_ids, role) do
    base = from(mc in "movie_credits", select: mc.movie_id, where: mc.person_id in ^people_ids)

    case role do
      "director" ->
        where(base, [mc], mc.job == "Director")

      "cast" ->
        where(base, [mc], mc.credit_type == "cast")

      "writer" ->
        where(
          base,
          [mc],
          mc.job in ["Writer", "Screenplay", "Story", "Novel", "Characters", "Teleplay", "Adaptation"]
        )

      "producer" ->
        where(
          base,
          [mc],
          mc.job in [
            "Producer",
            "Executive Producer",
            "Associate Producer",
            "Co-Producer",
            "Line Producer"
          ]
        )

      "cinematographer" ->
        where(base, [mc], mc.job in ["Director of Photography", "Cinematography", "Cinematographer"])

      "composer" ->
        where(base, [mc], mc.job in ["Original Music Composer", "Composer", "Music", "Music Score"])

      "editor" ->
        where(base, [mc], mc.job in ["Editor", "Film Editor", "Editorial", "Editing"])

      _ ->
        base
    end
  end

  # Metric threshold filters
  defp filter_by_metric_thresholds(query, params) do
    query
    |> filter_by_metric(:popular_opinion, params.popular_opinion_min)
    |> filter_by_metric(:industry_recognition, params.industry_recognition_min)
    |> filter_by_metric(:cultural_impact, params.cultural_impact_min)
    |> filter_by_metric(:people_quality, params.people_quality_min)
  end

  defp filter_by_metric(query, _dimension, nil), do: query

  defp filter_by_metric(query, :popular_opinion, min_value) do
    where(
      query,
      [m],
      fragment(
        """
        COALESCE((
          SELECT (COALESCE(tr.value, 0) / 10.0 * 0.25 + 
                  COALESCE(ir.value, 0) / 10.0 * 0.25 +
                  COALESCE(mc.value, 0) / 100.0 * 0.25 + 
                  COALESCE(rt.value, 0) / 100.0 * 0.25)
          FROM (
                SELECT value FROM external_metrics
                WHERE movie_id = ? AND source = 'tmdb' AND metric_type = 'rating_average'
                ORDER BY fetched_at DESC LIMIT 1
               ) tr,
               (
                SELECT value FROM external_metrics
                WHERE movie_id = ? AND source = 'imdb' AND metric_type = 'rating_average'
                ORDER BY fetched_at DESC LIMIT 1
               ) ir,
               (
                SELECT value FROM external_metrics
                WHERE movie_id = ? AND source = 'metacritic' AND metric_type = 'metascore'
                ORDER BY fetched_at DESC LIMIT 1
               ) mc,
               (
                SELECT value FROM external_metrics
                WHERE movie_id = ? AND source = 'rotten_tomatoes' AND metric_type = 'tomatometer'
                ORDER BY fetched_at DESC LIMIT 1
               ) rt
        ), 0) >= ?
        """,
        m.id,
        m.id,
        m.id,
        m.id,
        ^min_value
      )
    )
  end

  defp filter_by_metric(query, :industry_recognition, min_value) do
    where(
      query,
      [m],
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
    where(
      query,
      [m],
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
    where(
      query,
      [m],
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

defmodule Cinegraph.Movies.Filters do
  @moduledoc """
  Provides filtering and search functionality for movies.
  Handles complex queries with multiple filters, sorting, and pagination.
  """

  import Ecto.Query

  @doc """
  Apply all filters to a movie query.
  """
  def apply_filters(query, params) do
    query
    |> filter_by_search(params["search"])
    |> filter_by_genres(params["genres"])
    |> filter_by_countries(params["countries"])
    |> filter_by_languages(params["languages"])
    |> filter_by_year(params["year"])
    |> filter_by_year_range(params["year_from"], params["year_to"])
    |> filter_by_decade(params["decade"])
    |> filter_by_lists(params["lists"])
    |> filter_by_runtime(params["runtime_min"], params["runtime_max"])
    |> filter_by_rating(params["rating_min"])
    |> filter_unreleased(params["show_unreleased"])
    # New advanced filters
    |> filter_by_awards(params)
    |> filter_by_ratings(params)
    |> filter_by_people(params)
    |> filter_by_metric_scores(params)
    # Apply distinct only once at the end if any joins were added
    |> maybe_distinct()
  end

  defp maybe_distinct(query) do
    # Apply distinct if the query has joins to avoid duplicate rows
    if has_joins?(query) do
      distinct(query, true)
    else
      query
    end
  end

  defp has_joins?(%Ecto.Query{joins: joins}) when length(joins) > 0, do: true
  defp has_joins?(_), do: false

  @doc """
  Apply sorting to a movie query.
  """
  def apply_sorting(query, params) do
    case params["sort"] do
      "title" ->
        order_by(query, [m], asc: m.title)

      "title_desc" ->
        order_by(query, [m], desc: m.title)

      "release_date" ->
        order_by(query, [m], asc: m.release_date)

      "release_date_desc" ->
        order_by(query, [m], desc: m.release_date)

      "runtime" ->
        order_by(query, [m], asc: m.runtime)

      "runtime_desc" ->
        order_by(query, [m], desc: m.runtime)

      "date_added" ->
        order_by(query, [m], asc: m.inserted_at)

      "date_added_desc" ->
        order_by(query, [m], desc: m.inserted_at)

      "rating" ->
        query
        |> order_by([m],
          desc:
            fragment(
              """
              (SELECT value FROM external_metrics 
               WHERE movie_id = ? AND source = 'tmdb' AND metric_type = 'rating_average'
               ORDER BY fetched_at DESC LIMIT 1)
              """,
              m.id
            )
        )

      "popularity" ->
        query
        |> order_by([m],
          desc:
            fragment(
              """
              (SELECT value FROM external_metrics 
               WHERE movie_id = ? AND source = 'tmdb' AND metric_type = 'popularity_score'
               ORDER BY fetched_at DESC LIMIT 1)
              """,
              m.id
            )
        )

      # Discovery Metric Sorts
      "popular_opinion" ->
        sort_by_metric_dimension(query, :popular_opinion, :desc)

      "popular_opinion_asc" ->
        sort_by_metric_dimension(query, :popular_opinion, :asc)

      "industry_recognition" ->
        sort_by_metric_dimension(query, :industry_recognition, :desc)

      "industry_recognition_asc" ->
        sort_by_metric_dimension(query, :industry_recognition, :asc)

      "cultural_impact" ->
        sort_by_metric_dimension(query, :cultural_impact, :desc)

      "cultural_impact_asc" ->
        sort_by_metric_dimension(query, :cultural_impact, :asc)

      "people_quality" ->
        sort_by_metric_dimension(query, :people_quality, :desc)

      "people_quality_asc" ->
        sort_by_metric_dimension(query, :people_quality, :asc)

      # Default
      _ ->
        order_by(query, [m], desc: m.release_date)
    end
  end

  # Private sorting functions

  defp sort_by_metric_dimension(query, dimension, direction) do
    # Apply the ordering with the specific dimension score calculation
    case {dimension, direction} do
      {:popular_opinion, :desc} ->
        order_by(query, [m],
          desc:
            fragment(
              """
              COALESCE((
                SELECT (COALESCE(tr.value, 0) / 10.0 * 0.25 + 
                        COALESCE(ir.value, 0) / 10.0 * 0.25 +
                        COALESCE(mc.value, 0) / 100.0 * 0.25 + 
                        COALESCE(rt.value, 0) / 100.0 * 0.25)
                FROM (SELECT value FROM external_metrics WHERE movie_id = ? AND source = 'tmdb' AND metric_type = 'rating_average' ORDER BY fetched_at DESC LIMIT 1) tr,
                     (SELECT value FROM external_metrics WHERE movie_id = ? AND source = 'imdb' AND metric_type = 'rating_average' ORDER BY fetched_at DESC LIMIT 1) ir,
                     (SELECT value FROM external_metrics WHERE movie_id = ? AND source = 'metacritic' AND metric_type = 'metascore' ORDER BY fetched_at DESC LIMIT 1) mc,
                     (SELECT value FROM external_metrics WHERE movie_id = ? AND source = 'rotten_tomatoes' AND metric_type = 'tomatometer' ORDER BY fetched_at DESC LIMIT 1) rt
              ), 0)
              """,
              m.id,
              m.id,
              m.id,
              m.id
            )
        )

      {:popular_opinion, :asc} ->
        order_by(query, [m],
          asc:
            fragment(
              """
              COALESCE((
                SELECT (COALESCE(tr.value, 0) / 10.0 * 0.25 + 
                        COALESCE(ir.value, 0) / 10.0 * 0.25 +
                        COALESCE(mc.value, 0) / 100.0 * 0.25 + 
                        COALESCE(rt.value, 0) / 100.0 * 0.25)
                FROM (SELECT value FROM external_metrics WHERE movie_id = ? AND source = 'tmdb' AND metric_type = 'rating_average' ORDER BY fetched_at DESC LIMIT 1) tr,
                     (SELECT value FROM external_metrics WHERE movie_id = ? AND source = 'imdb' AND metric_type = 'rating_average' ORDER BY fetched_at DESC LIMIT 1) ir,
                     (SELECT value FROM external_metrics WHERE movie_id = ? AND source = 'metacritic' AND metric_type = 'metascore' ORDER BY fetched_at DESC LIMIT 1) mc,
                     (SELECT value FROM external_metrics WHERE movie_id = ? AND source = 'rotten_tomatoes' AND metric_type = 'tomatometer' ORDER BY fetched_at DESC LIMIT 1) rt
              ), 0)
              """,
              m.id,
              m.id,
              m.id,
              m.id
            )
        )

      {:industry_recognition, :desc} ->
        order_by(query, [m],
          desc:
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
              ), 0)
              """,
              m.id
            )
        )

      {:industry_recognition, :asc} ->
        order_by(query, [m],
          asc:
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
              ), 0)
              """,
              m.id
            )
        )

      {:cultural_impact, :desc} ->
        order_by(query, [m],
          desc:
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
              )
              """,
              m.canonical_sources,
              m.id
            )
        )

      {:cultural_impact, :asc} ->
        order_by(query, [m],
          asc:
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
              )
              """,
              m.canonical_sources,
              m.id
            )
        )

      {:people_quality, :desc} ->
        order_by(query, [m],
          desc:
            fragment(
              """
              COALESCE((
                SELECT AVG(DISTINCT pm.score) / 100.0
                FROM person_metrics pm
                JOIN movie_credits mc ON pm.person_id = mc.person_id
                WHERE mc.movie_id = ? AND pm.metric_type = 'quality_score'
              ), 0)
              """,
              m.id
            )
        )

      {:people_quality, :asc} ->
        order_by(query, [m],
          asc:
            fragment(
              """
              COALESCE((
                SELECT AVG(DISTINCT pm.score) / 100.0
                FROM person_metrics pm
                JOIN movie_credits mc ON pm.person_id = mc.person_id
                WHERE mc.movie_id = ? AND pm.metric_type = 'quality_score'
              ), 0)
              """,
              m.id
            )
        )
    end
  end

  # Private filter functions

  defp filter_by_search(query, nil), do: query
  defp filter_by_search(query, ""), do: query

  defp filter_by_search(query, search_term) do
    search_pattern = "%#{String.downcase(search_term)}%"

    where(
      query,
      [m],
      ilike(m.title, ^search_pattern) or
        ilike(m.original_title, ^search_pattern) or
        ilike(m.overview, ^search_pattern) or
        ilike(m.tagline, ^search_pattern)
    )
  end

  defp filter_by_genres(query, nil), do: query
  defp filter_by_genres(query, []), do: query

  defp filter_by_genres(query, genre_ids) when is_list(genre_ids) do
    genre_ids = Enum.map(genre_ids, &to_integer/1) |> Enum.reject(&is_nil/1)

    if Enum.empty?(genre_ids) do
      query
    else
      query
      |> join(:inner, [m], mg in "movie_genres", on: mg.movie_id == m.id)
      |> where([m, mg], mg.genre_id in ^genre_ids)
      |> group_by([m], m.id)
      |> having([m], count(m.id) == ^length(genre_ids))
    end
  end

  defp filter_by_genres(query, genre_ids) when is_binary(genre_ids) do
    # Handle comma-separated string
    genre_list = String.split(genre_ids, ",", trim: true)
    filter_by_genres(query, genre_list)
  end

  defp filter_by_countries(query, nil), do: query
  defp filter_by_countries(query, []), do: query

  defp filter_by_countries(query, country_ids) when is_list(country_ids) do
    country_ids = Enum.map(country_ids, &to_integer/1) |> Enum.reject(&is_nil/1)

    if Enum.empty?(country_ids) do
      query
    else
      query
      |> join(:inner, [m, ...], mpc in "movie_production_countries", on: mpc.movie_id == m.id)
      |> where([m, ..., mpc], mpc.production_country_id in ^country_ids)
    end
  end

  defp filter_by_countries(query, country_ids) when is_binary(country_ids) do
    country_list = String.split(country_ids, ",", trim: true)
    filter_by_countries(query, country_list)
  end

  defp filter_by_languages(query, nil), do: query
  defp filter_by_languages(query, []), do: query

  defp filter_by_languages(query, language_codes) when is_list(language_codes) do
    if Enum.empty?(language_codes) do
      query
    else
      # Filter by original_language field directly (ISO 639-1 codes)
      query
      |> where([m], m.original_language in ^language_codes)
    end
  end

  defp filter_by_languages(query, language_codes) when is_binary(language_codes) do
    language_list = String.split(language_codes, ",", trim: true)
    filter_by_languages(query, language_list)
  end

  defp filter_by_year(query, nil), do: query
  defp filter_by_year(query, ""), do: query

  defp filter_by_year(query, year) do
    case to_integer(year) do
      nil ->
        query

      year_int ->
        where(query, [m], fragment("EXTRACT(YEAR FROM ?) = ?", m.release_date, ^year_int))
    end
  end

  defp filter_by_year_range(query, nil, nil), do: query

  defp filter_by_year_range(query, year_from, nil) do
    case to_integer(year_from) do
      nil ->
        query

      year_int ->
        from_date = Date.new!(year_int, 1, 1)
        where(query, [m], m.release_date >= ^from_date)
    end
  end

  defp filter_by_year_range(query, nil, year_to) do
    case to_integer(year_to) do
      nil ->
        query

      year_int ->
        to_date = Date.new!(year_int, 12, 31)
        where(query, [m], m.release_date <= ^to_date)
    end
  end

  defp filter_by_year_range(query, year_from, year_to) do
    query
    |> filter_by_year_range(year_from, nil)
    |> filter_by_year_range(nil, year_to)
  end

  defp filter_by_decade(query, nil), do: query
  defp filter_by_decade(query, ""), do: query

  defp filter_by_decade(query, decade) do
    case to_integer(decade) do
      nil ->
        query

      decade_int ->
        from_year = decade_int
        to_year = decade_int + 9
        from_date = Date.new!(from_year, 1, 1)
        to_date = Date.new!(to_year, 12, 31)

        where(query, [m], m.release_date >= ^from_date and m.release_date <= ^to_date)
    end
  end

  defp filter_by_lists(query, nil), do: query
  defp filter_by_lists(query, []), do: query

  defp filter_by_lists(query, list_keys) when is_list(list_keys) do
    if Enum.empty?(list_keys) do
      query
    else
      # Build a dynamic OR condition for multiple lists
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
  end

  defp filter_by_lists(query, list_keys) when is_binary(list_keys) do
    list_keys_list = String.split(list_keys, ",", trim: true)
    filter_by_lists(query, list_keys_list)
  end

  defp filter_by_runtime(query, nil, nil), do: query

  defp filter_by_runtime(query, min, nil) do
    case to_integer(min) do
      nil -> query
      min_int -> where(query, [m], m.runtime >= ^min_int)
    end
  end

  defp filter_by_runtime(query, nil, max) do
    case to_integer(max) do
      nil -> query
      max_int -> where(query, [m], m.runtime <= ^max_int)
    end
  end

  defp filter_by_runtime(query, min, max) do
    query
    |> filter_by_runtime(min, nil)
    |> filter_by_runtime(nil, max)
  end

  defp filter_by_rating(query, nil), do: query
  defp filter_by_rating(query, ""), do: query

  defp filter_by_rating(query, min_rating) do
    case to_float(min_rating) do
      nil ->
        query

      rating ->
        query
        |> join(:inner, [m, ...], em in "external_metrics",
          on:
            em.movie_id == m.id and
              em.source == "tmdb" and
              em.metric_type == "rating_average"
        )
        |> where([m, ..., em], em.value >= ^rating)
    end
  end

  # When show_unreleased is true, show all movies
  defp filter_unreleased(query, "true"), do: query
  defp filter_unreleased(query, true), do: query

  # By default, hide movies without release dates or with future release dates
  defp filter_unreleased(query, _) do
    today = Date.utc_today()
    where(query, [m], not is_nil(m.release_date) and m.release_date <= ^today)
  end

  # Award-based filtering functions

  defp filter_by_awards(query, params) do
    query
    |> filter_by_award_status(params["award_status"])
    |> filter_by_festival(params["festival_id"])
    |> filter_by_award_category(params["award_category_id"])
    |> filter_by_award_year_range(params["award_year_from"], params["award_year_to"])
  end

  defp filter_by_award_status(query, nil), do: query
  defp filter_by_award_status(query, ""), do: query

  defp filter_by_award_status(query, status) do
    case status do
      "any_nomination" ->
        query
        |> join(:inner, [m], nom in "festival_nominations", on: nom.movie_id == m.id)

      "won" ->
        query
        |> join(:inner, [m], nom in "festival_nominations",
          on: nom.movie_id == m.id and nom.won == true
        )

      "nominated_only" ->
        query
        |> join(:inner, [m], nom in "festival_nominations",
          on: nom.movie_id == m.id and nom.won == false
        )

      "multiple_awards" ->
        query
        |> join(:inner, [m], nom in "festival_nominations",
          on: nom.movie_id == m.id and nom.won == true
        )
        |> group_by([m], m.id)
        |> having([m, nom], count(nom.id) > 1)

      _ ->
        query
    end
  end

  defp filter_by_festival(query, nil), do: query
  defp filter_by_festival(query, ""), do: query

  defp filter_by_festival(query, festival_org_id) do
    festival_id = to_integer(festival_org_id)

    if festival_id do
      query
      |> join(:inner, [m, ...], nom in "festival_nominations", on: nom.movie_id == m.id)
      |> join(:inner, [..., nom], fc in "festival_ceremonies", on: fc.id == nom.ceremony_id)
      |> where([..., fc], fc.organization_id == ^festival_id)
    else
      query
    end
  end

  defp filter_by_award_category(query, nil), do: query
  defp filter_by_award_category(query, ""), do: query

  defp filter_by_award_category(query, category_id) do
    cat_id = to_integer(category_id)

    if cat_id do
      query
      |> join(:inner, [m, ...], nom in "festival_nominations", on: nom.movie_id == m.id)
      |> where([..., nom], nom.category_id == ^cat_id)
    else
      query
    end
  end

  defp filter_by_award_year_range(query, nil, nil), do: query

  defp filter_by_award_year_range(query, year_from, year_to) do
    from_year = to_integer(year_from)
    to_year = to_integer(year_to)

    query =
      if from_year do
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

  # Rating-based filtering functions

  defp filter_by_ratings(query, params) do
    query
    # Only apply new rating preset if it's actually set
    |> maybe_apply_simple_rating(params["rating_preset"])
    # Keep legacy support for min/max ranges
    |> filter_by_tmdb_rating(params["tmdb_min"], params["tmdb_max"])
    |> filter_by_imdb_rating(params["imdb_min"], params["imdb_max"])
    |> filter_by_metacritic_rating(params["metacritic_min"], params["metacritic_max"])
    |> filter_by_rotten_tomatoes(params["rt_critics_min"], params["rt_audience_min"])
  end

  # Conditional wrapper to avoid function calls when not needed
  defp maybe_apply_simple_rating(query, preset) when preset in [nil, ""], do: query
  defp maybe_apply_simple_rating(query, preset), do: filter_by_simple_rating(query, preset)

  # New simplified rating filter
  defp filter_by_simple_rating(query, nil), do: query
  defp filter_by_simple_rating(query, ""), do: query

  defp filter_by_simple_rating(query, preset) do
    case preset do
      "highly_rated" ->
        # Movies with average TMDb/IMDb rating >= 7.5
        query
        |> join(:left, [m], tmdb in "external_metrics",
          on:
            tmdb.movie_id == m.id and tmdb.source == "tmdb" and
              tmdb.metric_type == "rating_average"
        )
        |> join(:left, [m, ...], imdb in "external_metrics",
          on:
            imdb.movie_id == m.id and imdb.source == "imdb" and
              imdb.metric_type == "rating_average"
        )
        |> where(
          [m, tmdb, imdb],
          fragment("(COALESCE(?, 0) + COALESCE(?, 0)) / 2 >= 7.5", tmdb.value, imdb.value)
        )

      "well_reviewed" ->
        # Movies with average TMDb/IMDb rating >= 6.0
        query
        |> join(:left, [m], tmdb in "external_metrics",
          on:
            tmdb.movie_id == m.id and tmdb.source == "tmdb" and
              tmdb.metric_type == "rating_average"
        )
        |> join(:left, [m, ...], imdb in "external_metrics",
          on:
            imdb.movie_id == m.id and imdb.source == "imdb" and
              imdb.metric_type == "rating_average"
        )
        |> where(
          [m, tmdb, imdb],
          fragment("(COALESCE(?, 0) + COALESCE(?, 0)) / 2 >= 6.0", tmdb.value, imdb.value)
        )

      "critically_acclaimed" ->
        # Movies with high Metacritic (>= 70) or high RT Critics (>= 80)
        query
        |> join(:left, [m], mc in "external_metrics",
          on: mc.movie_id == m.id and mc.source == "metacritic" and mc.metric_type == "metascore"
        )
        |> join(:left, [m, ...], rt in "external_metrics",
          on:
            rt.movie_id == m.id and rt.source == "rotten_tomatoes" and
              rt.metric_type == "tomatometer"
        )
        |> where(
          [m, mc, rt],
          fragment("COALESCE(?, 0) >= 70 OR COALESCE(?, 0) >= 80", mc.value, rt.value)
        )

      _ ->
        query
    end
  end

  defp filter_by_tmdb_rating(query, nil, nil), do: query

  defp filter_by_tmdb_rating(query, min, max) do
    min_val = to_float(min)
    max_val = to_float(max)

    query =
      if min_val do
        query
        |> join(:inner, [m, ...], em in "external_metrics",
          on: em.movie_id == m.id and em.source == "tmdb" and em.metric_type == "rating_average"
        )
        |> where([..., em], em.value >= ^min_val)
      else
        query
      end

    if max_val do
      query
      |> join(:inner, [m, ...], em in "external_metrics",
        on: em.movie_id == m.id and em.source == "tmdb" and em.metric_type == "rating_average"
      )
      |> where([..., em], em.value <= ^max_val)
    else
      query
    end
  end

  defp filter_by_imdb_rating(query, nil, nil), do: query

  defp filter_by_imdb_rating(query, min, max) do
    min_val = to_float(min)
    max_val = to_float(max)

    query =
      if min_val do
        query
        |> join(:inner, [m, ...], em in "external_metrics",
          on: em.movie_id == m.id and em.source == "imdb" and em.metric_type == "rating_average"
        )
        |> where([..., em], em.value >= ^min_val)
      else
        query
      end

    if max_val do
      query
      |> join(:inner, [m, ...], em in "external_metrics",
        on: em.movie_id == m.id and em.source == "imdb" and em.metric_type == "rating_average"
      )
      |> where([..., em], em.value <= ^max_val)
    else
      query
    end
  end

  defp filter_by_metacritic_rating(query, nil, nil), do: query

  defp filter_by_metacritic_rating(query, min, max) do
    min_val = to_float(min)
    max_val = to_float(max)

    query =
      if min_val do
        query
        |> join(:inner, [m, ...], em in "external_metrics",
          on: em.movie_id == m.id and em.source == "metacritic" and em.metric_type == "metascore"
        )
        |> where([..., em], em.value >= ^min_val)
      else
        query
      end

    if max_val do
      query
      |> join(:inner, [m, ...], em in "external_metrics",
        on: em.movie_id == m.id and em.source == "metacritic" and em.metric_type == "metascore"
      )
      |> where([..., em], em.value <= ^max_val)
    else
      query
    end
  end

  defp filter_by_rotten_tomatoes(query, nil, nil), do: query

  defp filter_by_rotten_tomatoes(query, critics_min, audience_min) do
    critics_val = to_float(critics_min)
    audience_val = to_float(audience_min)

    query =
      if critics_val do
        query
        |> join(:inner, [m, ...], em in "external_metrics",
          on:
            em.movie_id == m.id and em.source == "rotten_tomatoes" and
              em.metric_type == "tomatometer"
        )
        |> where([..., em], em.value >= ^critics_val)
      else
        query
      end

    if audience_val do
      query
      |> join(:inner, [m, ...], em in "external_metrics",
        on:
          em.movie_id == m.id and em.source == "rotten_tomatoes" and
            em.metric_type == "audience_score"
      )
      |> where([..., em], em.value >= ^audience_val)
    else
      query
    end
  end

  # People-based filtering functions

  defp filter_by_people(query, params) do
    query
    # Only apply new people search if it's actually set
    |> maybe_apply_people_search(params["people_search"])
    # Keep legacy support for backward compatibility
    |> filter_by_person_ids(params["person_ids"])
    |> filter_by_director_id(params["director_id"])
    |> filter_by_actor_ids(params["actor_ids"])
  end

  # Conditional wrapper to avoid function calls when not needed
  defp maybe_apply_people_search(query, nil), do: query

  defp maybe_apply_people_search(query, people_search),
    do: filter_by_unified_people_search(query, people_search)

  # New unified people search with role filtering - optimized for performance
  defp filter_by_unified_people_search(query, nil), do: query

  defp filter_by_unified_people_search(query, %{"people_ids" => "", "role_filter" => _}),
    do: query

  defp filter_by_unified_people_search(query, %{"people_ids" => people_ids})
       when people_ids != "" do
    # Basic filter case - no role filtering, just person IDs
    person_ids = parse_person_ids(people_ids)

    if Enum.empty?(person_ids) do
      query
    else
      # Single join for better performance - any role
      query
      |> join(:inner, [m], mc in "movie_credits", on: mc.movie_id == m.id, as: :credits)
      |> where([m, credits: mc], mc.person_id in ^person_ids)
    end
  end

  defp filter_by_unified_people_search(query, %{
         "people_ids" => people_ids,
         "role_filter" => role_filter
       }) do
    person_ids = parse_person_ids(people_ids)

    if Enum.empty?(person_ids) do
      query
    else
      # Single join for better performance
      query =
        join(query, :inner, [m], mc in "movie_credits", on: mc.movie_id == m.id, as: :credits)

      case role_filter do
        "director" ->
          where(query, [m, credits: mc], mc.person_id in ^person_ids and mc.job == "Director")

        "cast" ->
          where(query, [m, credits: mc], mc.person_id in ^person_ids and mc.credit_type == "cast")

        "writer" ->
          # Use specific job titles instead of ILIKE for better performance
          where(
            query,
            [m, credits: mc],
            mc.person_id in ^person_ids and
              mc.job in [
                "Writer",
                "Screenplay",
                "Story",
                "Novel",
                "Characters",
                "Teleplay",
                "Adaptation"
              ]
          )

        "producer" ->
          # Use specific job titles instead of ILIKE for better performance
          where(
            query,
            [m, credits: mc],
            mc.person_id in ^person_ids and
              mc.job in [
                "Producer",
                "Executive Producer",
                "Associate Producer",
                "Co-Producer",
                "Line Producer"
              ]
          )

        "cinematographer" ->
          where(
            query,
            [m, credits: mc],
            mc.person_id in ^person_ids and
              mc.job in ["Director of Photography", "Cinematography", "Cinematographer"]
          )

        "composer" ->
          # Use specific job titles instead of ILIKE for better performance
          where(
            query,
            [m, credits: mc],
            mc.person_id in ^person_ids and
              mc.job in ["Original Music Composer", "Composer", "Music", "Music Score"]
          )

        "editor" ->
          # Use specific job titles instead of ILIKE for better performance
          where(
            query,
            [m, credits: mc],
            mc.person_id in ^person_ids and
              mc.job in ["Editor", "Film Editor", "Editorial", "Editing"]
          )

        # "any" or default
        _ ->
          where(query, [m, credits: mc], mc.person_id in ^person_ids)
      end
    end
  end

  defp filter_by_unified_people_search(query, _), do: query

  defp parse_person_ids(person_ids) when is_binary(person_ids) and person_ids != "" do
    person_ids
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.map(&to_integer/1)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_person_ids(_), do: []

  # Legacy people filtering functions (kept for backward compatibility)
  defp filter_by_person_ids(query, nil), do: query
  defp filter_by_person_ids(query, []), do: query

  defp filter_by_person_ids(query, person_ids) when is_list(person_ids) do
    person_ids = Enum.map(person_ids, &to_integer/1) |> Enum.reject(&is_nil/1)

    if Enum.empty?(person_ids) do
      query
    else
      # Find movies with any of the selected people
      query
      |> join(:inner, [m], mc in "movie_credits", on: mc.movie_id == m.id)
      |> where([m, mc], mc.person_id in ^person_ids)
    end
  end

  defp filter_by_person_ids(query, person_ids) when is_binary(person_ids) do
    person_list = String.split(person_ids, ",", trim: true)
    filter_by_person_ids(query, person_list)
  end

  defp filter_by_director_id(query, nil), do: query
  defp filter_by_director_id(query, ""), do: query

  defp filter_by_director_id(query, director_id) do
    dir_id = to_integer(director_id)

    if dir_id do
      query
      |> join(:inner, [m, ...], mc in "movie_credits",
        on: mc.movie_id == m.id and mc.person_id == ^dir_id and mc.job == "Director"
      )
    else
      query
    end
  end

  defp filter_by_actor_ids(query, nil), do: query
  defp filter_by_actor_ids(query, []), do: query

  defp filter_by_actor_ids(query, actor_ids) when is_list(actor_ids) do
    actor_ids = Enum.map(actor_ids, &to_integer/1) |> Enum.reject(&is_nil/1)

    if Enum.empty?(actor_ids) do
      query
    else
      # Find movies with all of the selected actors (AND logic)
      Enum.reduce(actor_ids, query, fn actor_id, acc_query ->
        acc_query
        |> join(:inner, [m, ...], mc in "movie_credits",
          on: mc.movie_id == m.id and mc.person_id == ^actor_id and mc.credit_type == "cast"
        )
      end)
    end
  end

  defp filter_by_actor_ids(query, actor_ids) when is_binary(actor_ids) do
    actor_list = String.split(actor_ids, ",", trim: true)
    filter_by_actor_ids(query, actor_list)
  end

  # Metric score filtering functions

  defp filter_by_metric_scores(query, params) do
    query
    # Only apply new preset filters if they're actually set
    |> maybe_apply_discovery_preset(params["discovery_preset"])
    |> maybe_apply_award_preset(params["award_preset"])
    # Keep legacy support for numeric thresholds
    |> filter_by_metric_dimension(params["popular_opinion_min"], :popular_opinion)
    |> filter_by_metric_dimension(params["industry_recognition_min"], :industry_recognition)
    |> filter_by_metric_dimension(params["cultural_impact_min"], :cultural_impact)
    |> filter_by_metric_dimension(params["people_quality_min"], :people_quality)
  end

  # Conditional wrappers to avoid function calls when not needed
  defp maybe_apply_discovery_preset(query, preset) when preset in [nil, ""], do: query
  defp maybe_apply_discovery_preset(query, preset), do: filter_by_discovery_preset(query, preset)

  defp maybe_apply_award_preset(query, preset) when preset in [nil, ""], do: query
  defp maybe_apply_award_preset(query, preset), do: filter_by_award_preset(query, preset)

  # New simplified discovery metrics filter
  defp filter_by_discovery_preset(query, nil), do: query
  defp filter_by_discovery_preset(query, ""), do: query

  defp filter_by_discovery_preset(query, preset) do
    case preset do
      "award_winners" ->
        # Movies with at least one festival win
        query
        |> join(:inner, [m], festival_nomination in "festival_nominations",
          on: festival_nomination.movie_id == m.id and festival_nomination.won == true
        )

      "popular_favorites" ->
        # High popular opinion score (>= 0.7) - optimized with joins
        query
        |> join(:left, [m], tmdb_rating in "external_metrics",
          on:
            tmdb_rating.movie_id == m.id and tmdb_rating.source == "tmdb" and
              tmdb_rating.metric_type == "rating_average"
        )
        |> join(:left, [m, ...], imdb_rating in "external_metrics",
          on:
            imdb_rating.movie_id == m.id and imdb_rating.source == "imdb" and
              imdb_rating.metric_type == "rating_average"
        )
        |> where(
          [m, tmdb_rating, imdb_rating],
          fragment(
            "(COALESCE(?, 0) / 10.0 * 0.5 + COALESCE(?, 0) / 10.0 * 0.5) >= 0.7",
            tmdb_rating.value,
            imdb_rating.value
          )
        )

      "hidden_gems" ->
        # High critical acclaim but lower popularity (fewer votes)
        query
        |> join(:left, [m], tmdb_rating in "external_metrics",
          on:
            tmdb_rating.movie_id == m.id and tmdb_rating.source == "tmdb" and
              tmdb_rating.metric_type == "rating_average"
        )
        |> join(:left, [m, ...], tmdb_votes in "external_metrics",
          on:
            tmdb_votes.movie_id == m.id and tmdb_votes.source == "tmdb" and
              tmdb_votes.metric_type == "rating_votes"
        )
        |> where(
          [m, tmdb_rating, tmdb_votes],
          fragment(
            "COALESCE(?, 0) >= 7.0 AND COALESCE(?, 0) < 10000",
            tmdb_rating.value,
            tmdb_votes.value
          )
        )

      "critically_acclaimed" ->
        # High critical acclaim score (>= 0.6) - optimized with joins
        query
        |> join(:left, [m], metacritic in "external_metrics",
          on:
            metacritic.movie_id == m.id and metacritic.source == "metacritic" and
              metacritic.metric_type == "metascore"
        )
        |> join(:left, [m, ...], rotten_tomatoes in "external_metrics",
          on:
            rotten_tomatoes.movie_id == m.id and rotten_tomatoes.source == "rotten_tomatoes" and
              rotten_tomatoes.metric_type == "tomatometer"
        )
        |> where(
          [m, metacritic, rotten_tomatoes],
          fragment(
            "(COALESCE(?, 0) / 100.0 * 0.5 + COALESCE(?, 0) / 100.0 * 0.5) >= 0.6",
            metacritic.value,
            rotten_tomatoes.value
          )
        )

      _ ->
        query
    end
  end

  # New simplified award filter
  defp filter_by_award_preset(query, nil), do: query
  defp filter_by_award_preset(query, ""), do: query

  defp filter_by_award_preset(query, preset) do
    case preset do
      "recent_awards" ->
        # Awards from 2020 onwards
        query
        |> join(:inner, [m], festival_nomination in "festival_nominations",
          on: festival_nomination.movie_id == m.id
        )
        |> join(:inner, [..., festival_nomination], fc in "festival_ceremonies",
          on: fc.id == festival_nomination.ceremony_id
        )
        |> where([..., fc], fc.year >= 2020)

      "2010s" ->
        # Awards from 2010-2019
        query
        |> join(:inner, [m], festival_nomination in "festival_nominations",
          on: festival_nomination.movie_id == m.id
        )
        |> join(:inner, [..., festival_nomination], fc in "festival_ceremonies",
          on: fc.id == festival_nomination.ceremony_id
        )
        |> where([..., fc], fc.year >= 2010 and fc.year <= 2019)

      "2000s" ->
        # Awards from 2000-2009
        query
        |> join(:inner, [m], festival_nomination in "festival_nominations",
          on: festival_nomination.movie_id == m.id
        )
        |> join(:inner, [..., festival_nomination], fc in "festival_ceremonies",
          on: fc.id == festival_nomination.ceremony_id
        )
        |> where([..., fc], fc.year >= 2000 and fc.year <= 2009)

      "classic" ->
        # Awards from before 2000
        query
        |> join(:inner, [m], festival_nomination in "festival_nominations",
          on: festival_nomination.movie_id == m.id
        )
        |> join(:inner, [..., festival_nomination], fc in "festival_ceremonies",
          on: fc.id == festival_nomination.ceremony_id
        )
        |> where([..., fc], fc.year < 2000)

      _ ->
        query
    end
  end

  defp filter_by_metric_dimension(query, nil, _dimension), do: query
  defp filter_by_metric_dimension(query, "", _dimension), do: query

  defp filter_by_metric_dimension(query, min_value, dimension) do
    min_val = to_float(min_value)

    if min_val do
      case dimension do
        :popular_opinion ->
          # Filter by popular opinion score (all rating sources: TMDb + IMDb + Metacritic + RT)
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
                FROM (SELECT value FROM external_metrics WHERE movie_id = ? AND source = 'tmdb' AND metric_type = 'rating_average' ORDER BY fetched_at DESC LIMIT 1) tr,
                     (SELECT value FROM external_metrics WHERE movie_id = ? AND source = 'imdb' AND metric_type = 'rating_average' ORDER BY fetched_at DESC LIMIT 1) ir,
                     (SELECT value FROM external_metrics WHERE movie_id = ? AND source = 'metacritic' AND metric_type = 'metascore' ORDER BY fetched_at DESC LIMIT 1) mc,
                     (SELECT value FROM external_metrics WHERE movie_id = ? AND source = 'rotten_tomatoes' AND metric_type = 'tomatometer' ORDER BY fetched_at DESC LIMIT 1) rt
              ), 0) >= ?
              """,
              m.id,
              m.id,
              m.id,
              m.id,
              ^min_val
            )
          )

        :industry_recognition ->
          # Filter by industry recognition (awards)
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
              ^min_val
            )
          )

        :cultural_impact ->
          # Filter by cultural impact (canonical lists + popularity)
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
              ^min_val
            )
          )

        :people_quality ->
          # Filter by people quality score
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
              ^min_val
            )
          )

        _ ->
          query
      end
    else
      query
    end
  end

  # Helper functions

  defp to_integer(nil), do: nil
  defp to_integer(""), do: nil
  defp to_integer(value) when is_integer(value), do: value

  defp to_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> int
      :error -> nil
    end
  end

  defp to_float(nil), do: nil
  defp to_float(""), do: nil
  defp to_float(value) when is_float(value), do: value
  defp to_float(value) when is_integer(value), do: value * 1.0

  defp to_float(value) when is_binary(value) do
    case Float.parse(value) do
      {float, _} -> float
      :error -> nil
    end
  end
end

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
  end

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

      # Default
      _ ->
        order_by(query, [m], desc: m.release_date)
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
      |> distinct([m], m.id)
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
        |> distinct([m], m.id)
    end
  end

  defp filter_unreleased(query, "true"), do: query
  defp filter_unreleased(query, true), do: query

  defp filter_unreleased(query, _) do
    today = Date.utc_today()
    where(query, [m], m.release_date <= ^today or is_nil(m.release_date))
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

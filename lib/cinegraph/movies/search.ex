defmodule Cinegraph.Movies.Search do
  @moduledoc """
  Clean search interface that combines Flop with custom filters.
  This is the new unified interface for movie searching.

  All read operations use `Repo.replica()` to offload queries to
  PlanetScale read replicas, reducing load on the primary database.
  """

  import Ecto.Query
  alias Cinegraph.Repo
  alias Cinegraph.Movies.Movie
  alias Cinegraph.Movies.Query.{Params, CustomFilters, CustomSorting}

  @doc """
  Search movies with validated parameters.
  Returns {movies, meta} tuple where meta contains pagination info.
  Phase 2: Uses cache to avoid repeated database queries.
  """
  def search_movies(params \\ %{}) do
    # Use cache wrapper for search results (Phase 2 optimization)
    Cinegraph.Movies.Cache.get_search_results(params, fn ->
      search_movies_uncached(params)
    end)
  end

  @doc """
  Search movies without caching (internal use).
  This is the actual search implementation that gets cached.
  """
  def search_movies_uncached(params) do
    with {:ok, validated_params} <- Params.validate(params) do
      # Start with base query for fully imported movies
      base_query = from(m in Movie, where: m.import_status == "full")

      # Apply custom filters first (genres, awards, people, etc.)
      filtered_query = CustomFilters.apply_all(base_query, validated_params)

      # Check if we need custom sorting
      needs_custom_sort = validated_params.sort in ~w(
        rating rating_asc rating_desc
        popularity popularity_asc popularity_desc
        popular_opinion popular_opinion_asc popular_opinion_desc
        industry_recognition industry_recognition_asc industry_recognition_desc
        cultural_impact cultural_impact_asc cultural_impact_desc
        people_quality people_quality_asc people_quality_desc
      )

      # Apply custom sorting if needed
      sorted_query =
        if needs_custom_sort do
          CustomSorting.apply(filtered_query, validated_params.sort)
        else
          filtered_query
        end

      # Convert params to Flop format
      flop_params = Params.to_flop_params(validated_params)

      # If we applied custom sorting, remove order from Flop params
      flop_params =
        if needs_custom_sort do
          Map.delete(flop_params, :order_by)
        else
          flop_params
        end

      # Use Flop for remaining filters, sorting (if not custom), and pagination
      # Route to read replica for better load distribution
      case Flop.validate_and_run(sorted_query, flop_params, for: Movie, repo: Repo.replica()) do
        {:ok, {movies, meta}} ->
          # Add discovery scores for display if not using discovery sorting
          movies = maybe_add_discovery_scores(movies, validated_params.sort)
          {:ok, {movies, meta}}

        {:error, changeset} ->
          {:error, changeset}
      end
    end
  end

  @doc """
  Count total movies matching the filters.
  This is useful for showing total results without loading all data.
  """
  def count_movies(params \\ %{}) do
    with {:ok, validated_params} <- Params.validate(params) do
      base_query = from(m in Movie, where: m.import_status == "full")
      filtered_query = CustomFilters.apply_all(base_query, validated_params)

      # Handle special case for genre filtering with GROUP BY
      # Route to read replica for better load distribution
      count =
        if validated_params.genres && validated_params.genres != [] do
          # Wrap the grouped query in a subquery and count the results
          from(m in subquery(filtered_query), select: count())
          |> Repo.replica().one()
        else
          Repo.replica().aggregate(filtered_query, :count, :id)
        end

      {:ok, count}
    end
  end

  @doc """
  Get filter options for the UI.
  Returns all available values for dropdowns and multiselects.
  Uses cache to avoid repeated database queries (Phase 1 optimization).
  """
  def get_filter_options do
    Cinegraph.Movies.Cache.get_filter_options(fn ->
      %{
        genres: list_genres(),
        countries: list_production_countries(),
        languages: list_spoken_languages(),
        lists: list_canonical_lists(),
        decades: generate_decades(),
        festivals: list_festival_organizations(),
        sort_options: get_sort_options(),
        rating_presets: get_rating_presets(),
        discovery_presets: get_discovery_presets(),
        award_presets: get_award_presets(),
        people_roles: get_people_roles()
      }
    end)
  end

  @doc """
  Search for people to use in filters.
  """
  def search_people(query_string, limit \\ 10) do
    Cinegraph.People.search_people(query_string, limit: limit)
  end

  @doc """
  Get people by IDs for displaying selected filters.
  """
  def get_people_by_ids(ids) when is_list(ids) do
    Cinegraph.People.get_people_by_ids(ids)
  end

  # Private functions

  defp maybe_add_discovery_scores(movies, sort) do
    if uses_discovery_sorting?(sort) do
      # Discovery scores are already being used for sorting
      movies
    else
      # For now, skip adding scores when using Flop for basic sorting
      # TODO: Implement ScoringService.add_scores_to_loaded_movies/2 for this case
      movies
    end
  end

  defp uses_discovery_sorting?(sort) do
    base =
      cond do
        is_binary(sort) and String.ends_with?(sort, "_desc") ->
          String.replace_suffix(sort, "_desc", "")

        is_binary(sort) and String.ends_with?(sort, "_asc") ->
          String.replace_suffix(sort, "_asc", "")

        true ->
          sort
      end

    base in ~w(popular_opinion industry_recognition cultural_impact people_quality)
  end

  defp list_genres do
    from(g in Cinegraph.Movies.Genre, order_by: g.name)
    |> Repo.replica().all()
  end

  defp list_production_countries do
    from(c in Cinegraph.Movies.ProductionCountry, order_by: c.name)
    |> Repo.replica().all()
  end

  defp list_spoken_languages do
    from(l in Cinegraph.Movies.SpokenLanguage, order_by: l.english_name)
    |> Repo.replica().all()
  end

  defp list_canonical_lists do
    Cinegraph.Movies.MovieLists.get_active_source_keys()
    |> Enum.map(fn key ->
      case Cinegraph.Movies.MovieLists.get_config(key) do
        {:ok, config} -> %{id: key, key: key, name: config.name}
        _ -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp generate_decades do
    current_year = Date.utc_today().year
    start_decade = 1900

    for decade <- start_decade..current_year//10 do
      %{id: decade, value: decade, label: "#{decade}s"}
    end
    |> Enum.reverse()
  end

  defp list_festival_organizations do
    from(fo in "festival_organizations",
      select: %{id: fo.id, name: fo.name, abbreviation: fo.abbreviation},
      order_by: fo.name
    )
    |> Repo.replica().all()
  end

  defp get_sort_options do
    [
      %{id: "title", value: "title", label: "Title (A-Z)"},
      %{id: "title_desc", value: "title_desc", label: "Title (Z-A)"},
      %{id: "release_date", value: "release_date", label: "Release Date (Oldest)"},
      %{id: "release_date_desc", value: "release_date_desc", label: "Release Date (Newest)"},
      %{id: "runtime", value: "runtime", label: "Runtime (Shortest)"},
      %{id: "runtime_desc", value: "runtime_desc", label: "Runtime (Longest)"},
      %{id: "rating", value: "rating", label: "Rating (Highest)"},
      %{id: "popularity", value: "popularity", label: "Popularity"},
      %{id: "popular_opinion", value: "popular_opinion", label: "Popular Opinion"},
      %{id: "industry_recognition", value: "industry_recognition", label: "Industry Recognition"},
      %{id: "cultural_impact", value: "cultural_impact", label: "Cultural Impact"},
      %{id: "people_quality", value: "people_quality", label: "People Quality"}
    ]
  end

  defp get_rating_presets do
    [
      %{id: "highly_rated", value: "highly_rated", label: "Highly Rated (7.5+)"},
      %{id: "well_reviewed", value: "well_reviewed", label: "Well Reviewed (6.0+)"},
      %{id: "critically_acclaimed", value: "critically_acclaimed", label: "Critically Acclaimed"}
    ]
  end

  defp get_discovery_presets do
    [
      %{id: "award_winners", value: "award_winners", label: "Award Winners"},
      %{id: "popular_favorites", value: "popular_favorites", label: "Popular Favorites"},
      %{id: "hidden_gems", value: "hidden_gems", label: "Hidden Gems"},
      %{id: "critically_acclaimed", value: "critically_acclaimed", label: "Critically Acclaimed"}
    ]
  end

  defp get_award_presets do
    [
      %{id: "recent_awards", value: "recent_awards", label: "Recent Awards (2020+)"},
      %{id: "2010s", value: "2010s", label: "2010s Awards"},
      %{id: "2000s", value: "2000s", label: "2000s Awards"},
      %{id: "classic", value: "classic", label: "Classic Awards (Pre-2000)"}
    ]
  end

  defp get_people_roles do
    [
      %{id: "any", value: "any", label: "Any Role"},
      %{id: "director", value: "director", label: "Director"},
      %{id: "cast", value: "cast", label: "Cast"},
      %{id: "writer", value: "writer", label: "Writer"},
      %{id: "producer", value: "producer", label: "Producer"},
      %{id: "cinematographer", value: "cinematographer", label: "Cinematographer"},
      %{id: "composer", value: "composer", label: "Composer"},
      %{id: "editor", value: "editor", label: "Editor"}
    ]
  end
end

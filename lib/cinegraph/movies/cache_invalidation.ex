defmodule Cinegraph.Movies.CacheInvalidation do
  @moduledoc """
  Centralized cache invalidation logic for movies.

  This module provides functions to invalidate caches when data changes,
  ensuring cache consistency across the application.

  ## Usage

  Call these functions from your contexts or workers when data changes:

  - After movie import: `on_movie_import/1`
  - After metric update: `on_metrics_updated/1`
  - After award/festival data change: `on_awards_updated/0`
  - After filter data change: `on_filter_data_updated/0`
  """

  require Logger
  alias Cinegraph.Movies.Cache

  @doc """
  Invalidate caches when a new movie is imported.
  Invalidates ALL search results (since new movie affects all result pages)
  and discovery scores for the specific movie(s).
  """
  def on_movie_import(movie_id) when is_integer(movie_id) do
    Logger.info("[CacheInvalidation] Movie #{movie_id} imported, invalidating caches")

    # Invalidate search results (new movie appears in lists)
    Cache.invalidate_search_results()

    # Invalidate discovery scores for this movie
    Cache.invalidate_discovery_scores(movie_id)

    :ok
  end

  def on_movie_import(movie_ids) when is_list(movie_ids) do
    Logger.info("[CacheInvalidation] #{length(movie_ids)} movies imported, invalidating caches")

    # Invalidate search results
    Cache.invalidate_search_results()

    # Invalidate discovery scores for all imported movies
    Cache.invalidate_discovery_scores(movie_ids)

    :ok
  end

  @doc """
  Invalidate caches when movie metrics are updated.
  Invalidates ALL search results (since metrics affect sorting/filtering)
  and discovery scores for the specific movie(s).
  """
  def on_metrics_updated(movie_id) when is_integer(movie_id) do
    Logger.info("[CacheInvalidation] Metrics updated for movie #{movie_id}")

    # Metrics affect search results (sorting by ratings, popularity, etc.)
    Cache.invalidate_search_results()

    # Metrics affect discovery scores
    Cache.invalidate_discovery_scores(movie_id)

    :ok
  end

  def on_metrics_updated(movie_ids) when is_list(movie_ids) do
    Logger.info("[CacheInvalidation] Metrics updated for #{length(movie_ids)} movies")

    # Invalidate search results
    Cache.invalidate_search_results()

    # Invalidate discovery scores
    Cache.invalidate_discovery_scores(movie_ids)

    :ok
  end

  @doc """
  Invalidate caches when award/festival data is updated.
  Awards affect industry recognition scores and festival filters.
  """
  def on_awards_updated do
    Logger.info("[CacheInvalidation] Award data updated, invalidating caches")

    # Awards affect search results (festival filters, award winners, etc.)
    Cache.invalidate_search_results()

    # Awards affect industry recognition scores (part of discovery metrics)
    Cache.invalidate_all_discovery_scores()

    :ok
  end

  @doc """
  Invalidate caches when filter data is updated.
  This includes genres, countries, languages, canonical lists, festivals.
  """
  def on_filter_data_updated do
    Logger.info("[CacheInvalidation] Filter data updated")

    # Invalidate filter options cache
    Cache.invalidate_filter_options()

    # Filter changes might affect which movies appear in results
    Cache.invalidate_search_results()

    :ok
  end

  @doc """
  Full cache invalidation.
  Use sparingly - typically after major data changes or cache corruption.
  """
  def invalidate_all do
    Logger.warning("[CacheInvalidation] Performing full cache invalidation")

    Cache.clear_all()

    :ok
  end
end

# Comprehensive test with all TMDB data
# Run with: export TMDB_API_KEY=your_key && mix run test_comprehensive_100_movies.exs

import Ecto.Query
alias Cinegraph.{Movies, Repo}
alias Cinegraph.Services.TMDb

defmodule ComprehensiveMovieTest do
  @movie_count 100
  @batch_size 20
  
  def run do
    IO.puts("\n🎬 Comprehensive TMDB Integration Test - Phase 2")
    IO.puts("=" <> String.duplicate("=", 60))
    IO.puts("Fetching ALL available data from TMDB API\n")
    
    # Initialize statistics
    stats = %{
      movies_processed: 0,
      movies_failed: 0,
      people_created: 0,
      credits_created: 0,
      keywords_created: 0,
      videos_created: 0,
      release_dates_created: 0,
      collections_created: 0,
      companies_created: 0,
      images_stored: 0,
      external_ids_stored: 0,
      errors: []
    }
    
    # Step 1: Sync genres
    IO.puts("📚 Step 1: Syncing genres...")
    case Movies.sync_genres() do
      {:ok, :genres_synced} ->
        genres = Movies.list_genres()
        IO.puts("✅ Synced #{length(genres)} genres")
      {:error, reason} ->
        IO.puts("❌ Failed to sync genres: #{inspect(reason)}")
        exit(:genre_sync_failed)
    end
    
    # Step 2: Fetch movies with comprehensive data
    IO.puts("\n🎥 Step 2: Fetching #{@movie_count} movies with ALL data...")
    
    stats = fetch_movies_comprehensive(stats)
    
    # Display statistics
    display_comprehensive_statistics(stats)
    
    # Analyze data completeness
    analyze_data_completeness()
  end
  
  defp fetch_movies_comprehensive(stats) do
    pages_needed = div(@movie_count - 1, @batch_size) + 1
    
    Enum.reduce(1..pages_needed, stats, fn page, acc_stats ->
      IO.puts("\n📄 Fetching page #{page}/#{pages_needed}...")
      
      case TMDb.get_popular_movies(page: page) do
        {:ok, %{"results" => movies}} ->
          movies
          |> Enum.take(@batch_size)
          |> Enum.reduce(acc_stats, &process_movie_comprehensive/2)
          
        {:error, reason} ->
          IO.puts("❌ Failed to fetch page #{page}: #{inspect(reason)}")
          Map.update!(acc_stats, :errors, &[{:page_fetch, reason} | &1])
      end
    end)
  end
  
  defp process_movie_comprehensive(basic_movie, stats) do
    movie_id = basic_movie["id"]
    title = basic_movie["title"]
    
    IO.write("  Processing: #{title} (#{movie_id})... ")
    
    # Use comprehensive fetch that gets ALL data
    case Movies.fetch_and_store_movie_comprehensive(movie_id) do
      {:ok, movie} ->
        IO.puts("✅")
        
        # Count all related data
        stats
        |> Map.update!(:movies_processed, &(&1 + 1))
        |> count_movie_data(movie)
        
      {:error, reason} ->
        IO.puts("❌ #{inspect(reason)}")
        stats
        |> Map.update!(:movies_failed, &(&1 + 1))
        |> Map.update!(:errors, &[{movie_id, reason} | &1])
    end
  end
  
  defp count_movie_data(stats, movie) do
    # Count all related data for this movie
    credits = Repo.aggregate(from(c in Movies.Credit, where: c.movie_id == ^movie.id), :count)
    keywords = Repo.aggregate(from(mk in "movie_keywords", where: mk.movie_id == ^movie.id), :count)
    videos = Repo.aggregate(from(v in Movies.MovieVideo, where: v.movie_id == ^movie.id), :count)
    release_dates = Repo.aggregate(from(r in Movies.MovieReleaseDate, where: r.movie_id == ^movie.id), :count)
    
    # Check if we stored images and external IDs
    has_images = movie.images != %{} and map_size(movie.images) > 0
    has_external_ids = movie.external_ids != %{} and map_size(movie.external_ids) > 0
    
    stats
    |> Map.update!(:credits_created, &(&1 + credits))
    |> Map.update!(:keywords_created, &(&1 + keywords))
    |> Map.update!(:videos_created, &(&1 + videos))
    |> Map.update!(:release_dates_created, &(&1 + release_dates))
    |> Map.update!(:images_stored, &(if has_images, do: &1 + 1, else: &1))
    |> Map.update!(:external_ids_stored, &(if has_external_ids, do: &1 + 1, else: &1))
  end
  
  defp display_comprehensive_statistics(stats) do
    IO.puts("\n\n📊 COMPREHENSIVE DATA STATISTICS")
    IO.puts("=" <> String.duplicate("=", 60))
    IO.puts("Movies processed: #{stats.movies_processed}")
    IO.puts("Movies failed: #{stats.movies_failed}")
    
    IO.puts("\n📈 Data collected:")
    IO.puts("  Credits: #{stats.credits_created}")
    IO.puts("  Keywords: #{stats.keywords_created}")
    IO.puts("  Videos: #{stats.videos_created}")
    IO.puts("  Release dates: #{stats.release_dates_created}")
    IO.puts("  Movies with images: #{stats.images_stored}")
    IO.puts("  Movies with external IDs: #{stats.external_ids_stored}")
    
    # Calculate unique entities
    people_count = Repo.aggregate(Movies.Person, :count)
    keyword_count = Repo.aggregate(Movies.Keyword, :count)
    collection_count = Repo.aggregate(Movies.Collection, :count)
    company_count = Repo.aggregate(Movies.ProductionCompany, :count)
    
    IO.puts("\n🏢 Unique entities:")
    IO.puts("  People: #{people_count}")
    IO.puts("  Keywords: #{keyword_count}")
    IO.puts("  Collections: #{collection_count}")
    IO.puts("  Production companies: #{company_count}")
    
    if length(stats.errors) > 0 do
      IO.puts("\n❌ Errors (first 5):")
      stats.errors
      |> Enum.take(5)
      |> Enum.each(fn {id, error} ->
        IO.puts("  Movie #{id}: #{inspect(error)}")
      end)
    end
  end
  
  defp analyze_data_completeness do
    IO.puts("\n\n🔍 DATA COMPLETENESS ANALYSIS")
    IO.puts("=" <> String.duplicate("=", 60))
    
    total_movies = Repo.aggregate(Movies.Movie, :count)
    
    if total_movies > 0 do
      # Check image storage
      movies_with_images = Repo.aggregate(
        from(m in Movies.Movie, where: fragment("jsonb_array_length(? -> 'posters') > 0", m.images)),
        :count
      )
      
      # Check external IDs
      movies_with_external_ids = Repo.aggregate(
        from(m in Movies.Movie, where: fragment("? != '{}'::jsonb", m.external_ids)),
        :count
      )
      
      # Check keywords
      movies_with_keywords = Repo.one(
        from m in Movies.Movie,
        join: mk in "movie_keywords", on: mk.movie_id == m.id,
        select: count(m.id, :distinct)
      )
      
      # Check videos
      movies_with_videos = Repo.one(
        from m in Movies.Movie,
        join: v in Movies.MovieVideo, on: v.movie_id == m.id,
        select: count(m.id, :distinct)
      )
      
      IO.puts("Movies with comprehensive images: #{movies_with_images}/#{total_movies} (#{percent(movies_with_images, total_movies)}%)")
      IO.puts("Movies with external IDs: #{movies_with_external_ids}/#{total_movies} (#{percent(movies_with_external_ids, total_movies)}%)")
      IO.puts("Movies with keywords: #{movies_with_keywords}/#{total_movies} (#{percent(movies_with_keywords, total_movies)}%)")
      IO.puts("Movies with videos: #{movies_with_videos}/#{total_movies} (#{percent(movies_with_videos, total_movies)}%)")
      
      # Sample image data
      sample_movie = Repo.one(
        from m in Movies.Movie,
        where: fragment("jsonb_array_length(? -> 'posters') > 0", m.images),
        limit: 1
      )
      
      if sample_movie do
        IO.puts("\n📸 Sample image data for '#{sample_movie.title}':")
        images = sample_movie.images
        IO.puts("  Posters: #{length(images["posters"] || [])}")
        IO.puts("  Backdrops: #{length(images["backdrops"] || [])}")
        IO.puts("  Logos: #{length(images["logos"] || [])}")
      end
      
      # Sample external IDs
      sample_with_ids = Repo.one(
        from m in Movies.Movie,
        where: fragment("? != '{}'::jsonb", m.external_ids),
        limit: 1
      )
      
      if sample_with_ids do
        IO.puts("\n🔗 Sample external IDs for '#{sample_with_ids.title}':")
        Map.each(sample_with_ids.external_ids, fn {key, value} ->
          IO.puts("  #{key}: #{value}")
        end)
      end
    end
  end
  
  defp percent(count, total) when total > 0, do: Float.round(count / total * 100, 1)
  defp percent(_, _), do: 0
end

# Run the comprehensive test
ComprehensiveMovieTest.run()
# Run with: mix run test_objective_subjective_split.exs

defmodule ObjectiveSubjectiveTest do
  alias Cinegraph.{Repo, Movies, ExternalSources}
  alias Cinegraph.Movies.{Movie, Person, Credit, MovieVideo, MovieReleaseDate}
  alias Cinegraph.ExternalSources.{Source, Rating, Recommendation}
  import Ecto.Query

  def run do
    IO.puts("\n🎬 Objective/Subjective Data Split Test")
    IO.puts("=" <> String.duplicate("=", 60))
    IO.puts("Testing comprehensive TMDB data ingestion with separated storage\n")
    
    # Sync genres first
    IO.puts("📚 Step 1: Syncing genres...")
    Movies.sync_genres()
    IO.puts("✅ Genres synced")
    
    # Create or get TMDB source
    IO.puts("\n🔌 Step 2: Setting up external sources...")
    {:ok, tmdb_source} = ExternalSources.get_or_create_source("tmdb", %{
      source_type: "api",
      base_url: "https://api.themoviedb.org/3",
      api_version: "3"
    })
    IO.puts("✅ TMDB source configured")
    
    # Test movies
    movie_tmdb_ids = [
      1184918,  # The Wild Robot
      533535,   # Deadpool & Wolverine
      945961,   # Alien: Romulus
      519182,   # Despicable Me 4
      1022789,  # Inside Out 2
      573435,   # Bad Boys: Ride or Die
      653346,   # Kingdom of the Planet of the Apes
      929590,   # Civil War
      639720,   # IF
      693134    # Dune: Part Two
    ]
    
    IO.puts("\n🎬 Step 3: Fetching and storing #{length(movie_tmdb_ids)} movies...")
    
    results = movie_tmdb_ids
    |> Enum.with_index(1)
    |> Enum.map(fn {tmdb_id, index} ->
      IO.write("  #{index}/#{length(movie_tmdb_ids)} - Fetching movie #{tmdb_id}... ")
      
      case Movies.fetch_and_store_movie_comprehensive(tmdb_id) do
        {:ok, movie} ->
          # Count related data
          credits = Repo.aggregate(from(c in Credit, where: c.movie_id == ^movie.id), :count)
          videos = Repo.aggregate(from(v in MovieVideo, where: v.movie_id == ^movie.id), :count)
          release_dates = Repo.aggregate(from(r in MovieReleaseDate, where: r.movie_id == ^movie.id), :count)
          
          # Count subjective data
          ratings = Repo.aggregate(from(r in Rating, where: r.movie_id == ^movie.id), :count)
          recommendations = Repo.aggregate(
            from(r in Recommendation, where: r.source_movie_id == ^movie.id), 
            :count
          )
          
          IO.puts("✅ #{movie.title}")
          IO.puts("     Credits: #{credits}, Videos: #{videos}, Release dates: #{release_dates}")
          IO.puts("     Ratings: #{ratings}, Recommendations: #{recommendations}")
          
          {:ok, movie, %{
            credits: credits,
            videos: videos,
            release_dates: release_dates,
            ratings: ratings,
            recommendations: recommendations
          }}
        {:error, reason} ->
          IO.puts("❌ Error: #{inspect(reason)}")
          {:error, tmdb_id, reason}
      end
    end)
    
    # Analyze results
    successful = Enum.filter(results, fn 
      {:ok, _, _} -> true
      _ -> false
    end)
    
    IO.puts("\n📊 RESULTS SUMMARY")
    IO.puts("=" <> String.duplicate("=", 60))
    IO.puts("Movies processed: #{length(successful)}/#{length(movie_tmdb_ids)}")
    
    if length(successful) > 0 do
      # Aggregate stats
      total_credits = successful |> Enum.map(fn {:ok, _, stats} -> stats.credits end) |> Enum.sum()
      total_videos = successful |> Enum.map(fn {:ok, _, stats} -> stats.videos end) |> Enum.sum()
      total_release_dates = successful |> Enum.map(fn {:ok, _, stats} -> stats.release_dates end) |> Enum.sum()
      total_ratings = successful |> Enum.map(fn {:ok, _, stats} -> stats.ratings end) |> Enum.sum()
      total_recommendations = successful |> Enum.map(fn {:ok, _, stats} -> stats.recommendations end) |> Enum.sum()
      
      IO.puts("\n📈 Objective Data Collected:")
      IO.puts("  Total credits: #{total_credits}")
      IO.puts("  Total videos: #{total_videos}")
      IO.puts("  Total release dates: #{total_release_dates}")
      IO.puts("  Unique people: #{Repo.aggregate(Person, :count)}")
      
      IO.puts("\n📊 Subjective Data (External Sources):")
      IO.puts("  Total ratings: #{total_ratings}")
      IO.puts("  - User ratings: #{Repo.aggregate(from(r in Rating, where: r.rating_type == "user"), :count)}")
      IO.puts("  - Popularity scores: #{Repo.aggregate(from(r in Rating, where: r.rating_type == "popularity"), :count)}")
      IO.puts("  Total recommendations: #{total_recommendations}")
      
      # Sample analysis
      analyze_data_quality()
    end
  end
  
  defp analyze_data_quality do
    IO.puts("\n🔍 DATA QUALITY ANALYSIS")
    IO.puts("=" <> String.duplicate("=", 60))
    
    # Check objective data completeness
    total_movies = Repo.aggregate(Movie, :count)
    
    movies_with_images = Repo.aggregate(
      from(m in Movie, where: fragment("? != '{}'::jsonb", m.images)),
      :count
    )
    
    movies_with_external_ids = Repo.aggregate(
      from(m in Movie, where: fragment("? != '{}'::jsonb", m.external_ids)),
      :count
    )
    
    movies_with_keywords = Repo.one(
      from m in Movie,
      join: mk in "movie_keywords", on: mk.movie_id == m.id,
      select: count(m.id, :distinct)
    )
    
    movies_with_videos = Repo.one(
      from m in Movie,
      join: v in MovieVideo, on: v.movie_id == m.id,
      select: count(m.id, :distinct)
    )
    
    IO.puts("Objective Data Completeness:")
    IO.puts("  Movies with images: #{movies_with_images}/#{total_movies} (#{percent(movies_with_images, total_movies)}%)")
    IO.puts("  Movies with external IDs: #{movies_with_external_ids}/#{total_movies} (#{percent(movies_with_external_ids, total_movies)}%)")
    IO.puts("  Movies with keywords: #{movies_with_keywords}/#{total_movies} (#{percent(movies_with_keywords, total_movies)}%)")
    IO.puts("  Movies with videos: #{movies_with_videos}/#{total_movies} (#{percent(movies_with_videos, total_movies)}%)")
    
    # Check subjective data
    movies_with_user_ratings = Repo.one(
      from m in Movie,
      join: r in Rating, on: r.movie_id == m.id and r.rating_type == "user",
      select: count(m.id, :distinct)
    )
    
    movies_with_recommendations = Repo.one(
      from m in Movie,
      join: r in Recommendation, on: r.source_movie_id == m.id,
      select: count(m.id, :distinct)
    )
    
    IO.puts("\nSubjective Data Coverage:")
    IO.puts("  Movies with user ratings: #{movies_with_user_ratings}/#{total_movies} (#{percent(movies_with_user_ratings, total_movies)}%)")
    IO.puts("  Movies with recommendations: #{movies_with_recommendations}/#{total_movies} (#{percent(movies_with_recommendations, total_movies)}%)")
    
    # Sample normalized scores
    sample_movie = Repo.one(from m in Movie, limit: 1)
    if sample_movie do
      IO.puts("\n📈 Sample Normalized Scores for '#{sample_movie.title}':")
      scores = ExternalSources.get_normalized_scores(sample_movie.id)
      Enum.each(scores, fn score ->
        IO.puts("  #{score.source}: #{Float.round(score.normalized_score, 2)}/10 (raw: #{score.raw_value}/#{score.scale_max})")
      end)
      
      weighted = ExternalSources.calculate_weighted_score(sample_movie.id)
      if weighted, do: IO.puts("  Weighted average: #{Float.round(weighted, 2)}/10")
    end
    
    # Sample recommendations
    sample_with_recs = Repo.one(
      from m in Movie,
      join: r in Recommendation, on: r.source_movie_id == m.id,
      limit: 1
    )
    
    if sample_with_recs do
      IO.puts("\n🎯 Sample Recommendations for '#{sample_with_recs.title}':")
      recs = ExternalSources.get_movie_recommendations(sample_with_recs.id, limit: 5)
      Enum.each(recs, fn rec ->
        IO.puts("  #{rec.rank}. #{rec.recommended_movie.title} (#{rec.recommendation_type}, score: #{Float.round(rec.score || 0.0, 2)})")
      end)
    end
  end
  
  defp percent(count, total) when total > 0, do: Float.round(count / total * 100, 1)
  defp percent(_, _), do: 0.0
end

# Run the test
ObjectiveSubjectiveTest.run()
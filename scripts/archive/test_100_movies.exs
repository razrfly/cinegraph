# Comprehensive test to fetch 100 movies and validate our schema
# Run with: source .env && mix run test_100_movies.exs

import Ecto.Query
alias Cinegraph.{Movies, Repo}
alias Cinegraph.Services.TMDb
require Logger

defmodule MovieIngestionTest do
  @movie_count 100
  @batch_size 20
  
  def run do
    IO.puts("\n🎬 Starting comprehensive TMDB integration test")
    IO.puts("=" <> String.duplicate("=", 60))
    
    # Track statistics
    stats = %{
      movies_processed: 0,
      movies_failed: 0,
      people_created: 0,
      credits_created: 0,
      missing_fields: %{},
      errors: []
    }
    
    # Step 1: Sync genres
    IO.puts("\n📚 Step 1: Syncing genres...")
    case Movies.sync_genres() do
      {:ok, :genres_synced} ->
        genres = Movies.list_genres()
        IO.puts("✅ Synced #{length(genres)} genres")
      {:error, reason} ->
        IO.puts("❌ Failed to sync genres: #{inspect(reason)}")
        exit(:genre_sync_failed)
    end
    
    # Step 2: Fetch popular movies in batches
    IO.puts("\n🎥 Step 2: Fetching #{@movie_count} popular movies...")
    
    stats = fetch_movies_in_batches(stats)
    
    # Display final statistics
    display_statistics(stats)
    
    # Analyze schema usage
    analyze_schema_usage()
  end
  
  defp fetch_movies_in_batches(stats) do
    pages_needed = div(@movie_count - 1, @batch_size) + 1
    
    Enum.reduce(1..pages_needed, stats, fn page, acc_stats ->
      IO.puts("\n📄 Fetching page #{page}/#{pages_needed}...")
      
      case TMDb.get_popular_movies(page: page) do
        {:ok, %{"results" => movies}} ->
          movies
          |> Enum.take(@batch_size)
          |> Enum.reduce(acc_stats, &process_movie/2)
          
        {:error, reason} ->
          IO.puts("❌ Failed to fetch page #{page}: #{inspect(reason)}")
          Map.update!(acc_stats, :errors, &[{:page_fetch, reason} | &1])
      end
    end)
  end
  
  defp process_movie(basic_movie, stats) do
    movie_id = basic_movie["id"]
    title = basic_movie["title"]
    
    IO.write("  Processing: #{title} (#{movie_id})... ")
    
    # Fetch full movie details with append_to_response
    case fetch_full_movie_data(movie_id) do
      {:ok, movie_data} ->
        case process_movie_data(movie_data, stats) do
          {:ok, updated_stats} ->
            IO.puts("✅")
            updated_stats
          {:error, reason, updated_stats} ->
            IO.puts("❌ #{inspect(reason)}")
            updated_stats
        end
        
      {:error, reason} ->
        IO.puts("❌ API error: #{inspect(reason)}")
        stats
        |> Map.update!(:movies_failed, &(&1 + 1))
        |> Map.update!(:errors, &[{movie_id, reason} | &1])
    end
  end
  
  defp fetch_full_movie_data(movie_id) do
    # Fetch movie with additional data
    params = %{
      append_to_response: "credits,images,keywords,external_ids,release_dates"
    }
    
    TMDb.Client.get("/movie/#{movie_id}", params)
  end
  
  defp process_movie_data(movie_data, stats) do
    # Track missing fields
    stats = track_missing_fields(movie_data, stats)
    
    # Create or update movie
    case Movies.create_or_update_movie_from_tmdb(movie_data) do
      {:ok, movie} ->
        # Process credits
        credits_data = movie_data["credits"] || %{}
        {people_count, credits_count} = process_credits(movie, credits_data)
        
        # Process images if available
        if movie_data["images"] do
          process_images(movie, movie_data["images"])
        end
        
        {:ok, stats
          |> Map.update!(:movies_processed, &(&1 + 1))
          |> Map.update!(:people_created, &(&1 + people_count))
          |> Map.update!(:credits_created, &(&1 + credits_count))}
        
      {:error, changeset} ->
        errors = extract_changeset_errors(changeset)
        {:error, errors, stats
          |> Map.update!(:movies_failed, &(&1 + 1))
          |> Map.update!(:errors, &[{movie_data["id"], errors} | &1])}
    end
  end
  
  defp track_missing_fields(movie_data, stats) do
    expected_fields = ~w(
      id imdb_id title original_title release_date runtime overview
      tagline original_language popularity vote_average vote_count
      budget revenue status adult video homepage poster_path backdrop_path
      genres spoken_languages production_countries production_companies
      belongs_to_collection
    )
    
    missing = Enum.filter(expected_fields, fn field ->
      is_nil(movie_data[field])
    end)
    
    if length(missing) > 0 do
      Map.update!(stats, :missing_fields, fn mf ->
        Enum.reduce(missing, mf, fn field, acc ->
          Map.update(acc, field, 1, &(&1 + 1))
        end)
      end)
    else
      stats
    end
  end
  
  defp process_credits(movie, %{"cast" => cast, "crew" => crew}) do
    # Process cast members
    cast_results = cast
    |> Enum.take(20)  # Limit cast to top 20
    |> Enum.map(fn member -> process_cast_member(movie, member) end)
    
    # Process key crew members
    key_jobs = ["Director", "Producer", "Screenplay", "Writer", "Director of Photography", "Original Music Composer", "Editor"]
    crew_results = crew
    |> Enum.filter(& &1["job"] in key_jobs)
    |> Enum.map(fn member -> process_crew_member(movie, member) end)
    
    people_count = length(Enum.uniq_by(cast ++ crew, & &1["id"]))
    credits_count = length(cast_results) + length(crew_results)
    
    {people_count, credits_count}
  end
  defp process_credits(_movie, _), do: {0, 0}
  
  defp process_cast_member(movie, cast_member) do
    # First ensure person exists
    person_data = extract_person_data(cast_member)
    
    with {:ok, person} <- Movies.create_or_update_person_from_tmdb(person_data),
         credit_attrs <- %{
           movie_id: movie.id,
           person_id: person.id,
           credit_type: "cast",
           character: cast_member["character"],
           cast_order: cast_member["order"],
           credit_id: cast_member["credit_id"]
         },
         {:ok, _credit} <- Movies.create_credit(credit_attrs) do
      :ok
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        if has_unique_constraint_error?(changeset) do
          :already_exists
        else
          {:error, changeset}
        end
      error -> error
    end
  end
  
  defp process_crew_member(movie, crew_member) do
    person_data = extract_person_data(crew_member)
    
    with {:ok, person} <- Movies.create_or_update_person_from_tmdb(person_data),
         credit_attrs <- %{
           movie_id: movie.id,
           person_id: person.id,
           credit_type: "crew",
           department: crew_member["department"],
           job: crew_member["job"],
           credit_id: crew_member["credit_id"]
         },
         {:ok, _credit} <- Movies.create_credit(credit_attrs) do
      :ok
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        if has_unique_constraint_error?(changeset) do
          :already_exists
        else
          {:error, changeset}
        end
      error -> error
    end
  end
  
  defp extract_person_data(credit_data) do
    %{
      "id" => credit_data["id"],
      "name" => credit_data["name"],
      "gender" => credit_data["gender"],
      "profile_path" => credit_data["profile_path"],
      "known_for_department" => credit_data["known_for_department"],
      "popularity" => credit_data["popularity"],
      "adult" => credit_data["adult"] || false
    }
  end
  
  defp process_images(movie, images_data) do
    # Update movie with comprehensive image data
    images_map = %{
      "posters" => images_data["posters"] || [],
      "backdrops" => images_data["backdrops"] || [],
      "logos" => images_data["logos"] || []
    }
    
    Movies.update_movie(movie, %{images: images_map})
  end
  
  defp has_unique_constraint_error?(changeset) do
    Enum.any?(changeset.errors, fn {_, {_, opts}} ->
      opts[:constraint] == :unique
    end)
  end
  
  defp extract_changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end
  
  defp display_statistics(stats) do
    IO.puts("\n\n📊 FINAL STATISTICS")
    IO.puts("=" <> String.duplicate("=", 60))
    IO.puts("Movies processed: #{stats.movies_processed}")
    IO.puts("Movies failed: #{stats.movies_failed}")
    IO.puts("People created/updated: #{stats.people_created}")
    IO.puts("Credits created: #{stats.credits_created}")
    
    if map_size(stats.missing_fields) > 0 do
      IO.puts("\n⚠️  Fields with missing data:")
      stats.missing_fields
      |> Enum.sort_by(fn {_, count} -> -count end)
      |> Enum.each(fn {field, count} ->
        percentage = Float.round(count / stats.movies_processed * 100, 1)
        IO.puts("  - #{field}: #{count} movies (#{percentage}%)")
      end)
    end
    
    if length(stats.errors) > 0 do
      IO.puts("\n❌ Errors encountered:")
      stats.errors
      |> Enum.take(10)
      |> Enum.each(fn {movie_id, error} ->
        IO.puts("  - Movie #{movie_id}: #{inspect(error)}")
      end)
      
      if length(stats.errors) > 10 do
        IO.puts("  ... and #{length(stats.errors) - 10} more errors")
      end
    end
  end
  
  defp analyze_schema_usage do
    IO.puts("\n\n🔍 SCHEMA ANALYSIS")
    IO.puts("=" <> String.duplicate("=", 60))
    
    # Check movie data coverage
    movie_count = Repo.aggregate(Movies.Movie, :count, :id)
    IO.puts("\nMovies in database: #{movie_count}")
    
    # Check field usage
    if movie_count > 0 do
      sample_movies = Repo.all(from m in Movies.Movie, limit: 10)
      
      IO.puts("\nField usage analysis (sample of 10 movies):")
      
      # Check which fields are commonly null
      fields_to_check = [:imdb_id, :tagline, :homepage, :budget, :revenue, :video, :adult]
      
      Enum.each(fields_to_check, fn field ->
        null_count = Enum.count(sample_movies, &is_nil(Map.get(&1, field)))
        percentage = Float.round(null_count / length(sample_movies) * 100, 1)
        IO.puts("  - #{field}: #{null_count}/#{length(sample_movies)} null (#{percentage}%)")
      end)
      
      # Check array fields
      IO.puts("\nArray field usage:")
      Enum.each(sample_movies, fn movie ->
        IO.puts("  Movie: #{movie.title}")
        IO.puts("    - genre_ids: #{length(movie.genre_ids || [])}")
        IO.puts("    - spoken_languages: #{length(movie.spoken_languages || [])}")
        IO.puts("    - production_countries: #{length(movie.production_countries || [])}")
      end)
    end
    
    # Check people data
    person_count = Repo.aggregate(Movies.Person, :count, :id)
    credit_count = Repo.aggregate(Movies.Credit, :count, :id)
    
    IO.puts("\nPeople in database: #{person_count}")
    IO.puts("Credits in database: #{credit_count}")
    
    # Check credit distribution
    if credit_count > 0 do
      cast_count = Repo.aggregate(from(c in Movies.Credit, where: c.credit_type == "cast"), :count, :id)
      crew_count = Repo.aggregate(from(c in Movies.Credit, where: c.credit_type == "crew"), :count, :id)
      
      IO.puts("  - Cast credits: #{cast_count}")
      IO.puts("  - Crew credits: #{crew_count}")
      
      # Top departments
      IO.puts("\nTop crew departments:")
      Repo.all(
        from c in Movies.Credit,
        where: c.credit_type == "crew",
        group_by: c.department,
        select: {c.department, count(c.id)},
        order_by: [desc: count(c.id)],
        limit: 10
      )
      |> Enum.each(fn {dept, count} ->
        IO.puts("  - #{dept || "Unknown"}: #{count}")
      end)
    end
  end
end

# Run the test
MovieIngestionTest.run()
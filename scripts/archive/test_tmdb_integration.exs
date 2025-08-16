# Test script for TMDB integration
# Run with: mix run test_tmdb_integration.exs

alias Cinegraph.Movies
alias Cinegraph.Services.TMDb

IO.puts("\n🎬 Testing TMDB Integration with Database Models\n")

# Test 1: Sync genres from TMDB
IO.puts("1. Syncing genres from TMDB...")
case Movies.sync_genres() do
  {:ok, :genres_synced} ->
    genres = Movies.list_genres()
    IO.puts("✅ Successfully synced #{length(genres)} genres")
    Enum.take(genres, 5) |> Enum.each(fn genre ->
      IO.puts("   - #{genre.name} (TMDB ID: #{genre.tmdb_id})")
    end)
  {:error, reason} ->
    IO.puts("❌ Failed to sync genres: #{inspect(reason)}")
end

IO.puts("\n2. Testing movie fetch and store...")
# Test with Fight Club (ID: 550)
movie_id = 550

case Movies.fetch_and_store_movie(movie_id) do
  {:ok, movie} ->
    IO.puts("✅ Successfully fetched and stored movie:")
    IO.puts("   Title: #{movie.title}")
    IO.puts("   Release Date: #{movie.release_date}")
    IO.puts("   Overview: #{String.slice(movie.overview || "", 0, 100)}...")
    IO.puts("   Poster URL: #{Movies.Movie.poster_url(movie)}")
    IO.puts("   Vote Average: #{movie.vote_average}/10 (#{movie.vote_count} votes)")
    IO.puts("   Genres: #{inspect(movie.genre_ids)}")
  {:error, reason} ->
    IO.puts("❌ Failed to fetch movie: #{inspect(reason)}")
end

IO.puts("\n3. Testing movie credits fetch...")
# Fetch credits for the same movie
with {:ok, credits_data} <- TMDb.Client.get("/movie/#{movie_id}/credits"),
     movie <- Movies.get_movie_by_tmdb_id(movie_id) do
  
  IO.puts("📽️ Processing cast and crew...")
  
  # Process cast
  cast = credits_data["cast"] || []
  
  Enum.take(cast, 5) |> Enum.each(fn cast_member ->
    # Create or update person
    person_data = %{
      "id" => cast_member["id"],
      "name" => cast_member["name"],
      "gender" => cast_member["gender"],
      "profile_path" => cast_member["profile_path"],
      "known_for_department" => cast_member["known_for_department"],
      "popularity" => cast_member["popularity"]
    }
    
    case Movies.create_or_update_person_from_tmdb(person_data) do
      {:ok, person} ->
        # Create credit
        credit_attrs = %{
          movie_id: movie.id,
          person_id: person.id,
          credit_type: "cast",
          character: cast_member["character"],
          cast_order: cast_member["order"],
          credit_id: cast_member["credit_id"]
        }
        
        case Movies.create_credit(credit_attrs) do
          {:ok, _credit} ->
            IO.puts("   ✅ #{person.name} as #{cast_member["character"]}")
          {:error, _} ->
            IO.puts("   ℹ️  #{person.name} already credited")
        end
      {:error, reason} ->
        IO.puts("   ❌ Failed to create person: #{inspect(reason)}")
    end
  end)
  
  # Process key crew members (director, writers)
  crew = credits_data["crew"] || []
  directors = Enum.filter(crew, & &1["job"] == "Director")
  
  Enum.each(directors, fn crew_member ->
    person_data = %{
      "id" => crew_member["id"],
      "name" => crew_member["name"],
      "gender" => crew_member["gender"],
      "profile_path" => crew_member["profile_path"],
      "known_for_department" => crew_member["known_for_department"],
      "popularity" => crew_member["popularity"]
    }
    
    case Movies.create_or_update_person_from_tmdb(person_data) do
      {:ok, person} ->
        credit_attrs = %{
          movie_id: movie.id,
          person_id: person.id,
          credit_type: "crew",
          department: crew_member["department"],
          job: crew_member["job"],
          credit_id: crew_member["credit_id"]
        }
        
        case Movies.create_credit(credit_attrs) do
          {:ok, _credit} ->
            IO.puts("   ✅ #{person.name} - #{crew_member["job"]}")
          {:error, _} ->
            IO.puts("   ℹ️  #{person.name} already credited")
        end
      {:error, reason} ->
        IO.puts("   ❌ Failed to create crew member: #{inspect(reason)}")
    end
  end)
  
  IO.puts("\n✨ Integration test complete!")
else
  error ->
    IO.puts("❌ Failed to fetch credits: #{inspect(error)}")
end

# Test 4: Query the data
IO.puts("\n4. Testing data queries...")
if movie = Movies.get_movie_by_tmdb_id(movie_id) do
  credits = Movies.get_movie_credits(movie.id)
  cast = Enum.filter(credits, & &1.credit_type == "cast")
  crew = Enum.filter(credits, & &1.credit_type == "crew")
  
  IO.puts("📊 Movie has #{length(cast)} cast members and #{length(crew)} crew members in database")
end
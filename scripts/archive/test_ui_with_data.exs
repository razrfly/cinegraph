# Test script to populate sample data and test UI
# Run with: mix run test_ui_with_data.exs

Mix.Task.run("app.start")

IO.puts("🎬 Populating Sample Data for UI Testing")
IO.puts("=" <> String.duplicate("=", 60))

# Seed cultural authorities if not already present
authorities_count = Cinegraph.Repo.aggregate(Cinegraph.Cultural.Authority, :count)
if authorities_count == 0 do
  IO.puts("Seeding cultural authorities...")
  Cinegraph.Cultural.seed_authorities()
  IO.puts("✅ Authorities seeded")
else
  IO.puts("✅ Authorities already present: #{authorities_count}")
end

# Create sample movies if none exist
movies_count = Cinegraph.Repo.aggregate(Cinegraph.Movies.Movie, :count)
if movies_count == 0 do
  IO.puts("Creating sample movies...")
  
  # The Godfather
  {:ok, godfather} = Cinegraph.Movies.create_movie(%{
    tmdb_id: 238,
    title: "The Godfather",
    original_title: "The Godfather",
    release_date: ~D[1972-03-24],
    runtime: 175,
    overview: "Spanning the years 1945 to 1955, a chronicle of the fictional Italian-American Corleone crime family.",
    tagline: "An offer you can't refuse.",
    original_language: "en",
    budget: 6000000,
    revenue: 245066411,
    status: "Released",
    poster_path: "/3bhkrj58Vtu7enYsRolD1fZdja1.jpg"
  })
  
  # Citizen Kane
  {:ok, citizen_kane} = Cinegraph.Movies.create_movie(%{
    tmdb_id: 15,
    title: "Citizen Kane",
    original_title: "Citizen Kane", 
    release_date: ~D[1941-05-01],
    runtime: 119,
    overview: "Newspaper magnate, Charles Foster Kane is taken from his mother as a boy and made the ward of a rich industrialist.",
    tagline: "Some called him a hero... others called him a heel.",
    original_language: "en",
    budget: 839000,
    revenue: 1600000,
    status: "Released",
    poster_path: "/sav0jxhqiH0bPr2vZFU0Kjt2nZL.jpg"
  })
  
  # Casablanca
  {:ok, casablanca} = Cinegraph.Movies.create_movie(%{
    tmdb_id: 289,
    title: "Casablanca",
    original_title: "Casablanca",
    release_date: ~D[1942-11-26],
    runtime: 102,
    overview: "In Casablanca, Morocco in December 1941, a cynical American expatriate meets a former lover.",
    tagline: "They had a date with fate in... Casablanca!",
    original_language: "en",
    status: "Released",
    poster_path: "/5K7cOHoay2mZusSLezBOY0Qxh8a.jpg"
  })
  
  IO.puts("✅ Sample movies created")
  
  # Add movies to lists
  IO.puts("Adding movies to cultural lists...")
  
  # Get AFI list
  afi_list = Cinegraph.Repo.get_by(Cinegraph.Cultural.CuratedList, name: "AFI's 100 Years...100 Movies")
  
  if afi_list do
    # Add Citizen Kane as #1
    Cinegraph.Cultural.add_movie_to_list(citizen_kane.id, afi_list.id, %{
      rank: 1,
      notes: "Orson Welles' masterpiece - Greatest American film"
    })
    
    # Update The Godfather entry if it exists, or add it
    case Cinegraph.Repo.get_by(Cinegraph.Cultural.MovieListItem, movie_id: godfather.id, list_id: afi_list.id) do
      nil ->
        Cinegraph.Cultural.add_movie_to_list(godfather.id, afi_list.id, %{
          rank: 3,
          notes: "Francis Ford Coppola's epic crime saga"
        })
      _existing -> :ok
    end
    
    # Add Casablanca
    Cinegraph.Cultural.add_movie_to_list(casablanca.id, afi_list.id, %{
      rank: 2,
      notes: "Timeless romantic drama"
    })
    
    IO.puts("✅ Movies added to AFI Top 100")
  end
  
  # Add some awards data
  best_picture_list = Cinegraph.Repo.get_by(Cinegraph.Cultural.CuratedList, name: "Best Picture")
  
  if best_picture_list do
    # The Godfather won Best Picture 1973
    Cinegraph.Cultural.add_movie_to_list(godfather.id, best_picture_list.id, %{
      award_category: "Best Picture",
      award_result: "winner", 
      year_added: 1973,
      notes: "45th Academy Awards"
    })
    
    # Casablanca won Best Picture 1944
    Cinegraph.Cultural.add_movie_to_list(casablanca.id, best_picture_list.id, %{
      award_category: "Best Picture",
      award_result: "winner",
      year_added: 1944, 
      notes: "16th Academy Awards"
    })
    
    # Citizen Kane was nominated but didn't win
    Cinegraph.Cultural.add_movie_to_list(citizen_kane.id, best_picture_list.id, %{
      award_category: "Best Picture",
      award_result: "nominee",
      year_added: 1942,
      notes: "14th Academy Awards"
    })
    
    IO.puts("✅ Award data added")
  end
  
  # Calculate CRI scores
  IO.puts("Calculating CRI scores...")
  
  Cinegraph.Cultural.calculate_cri_score(godfather.id)
  Cinegraph.Cultural.calculate_cri_score(citizen_kane.id)
  Cinegraph.Cultural.calculate_cri_score(casablanca.id)
  
  IO.puts("✅ CRI scores calculated")
  
else
  IO.puts("✅ Movies already present: #{movies_count}")
end

# Display summary
movies = Cinegraph.Movies.list_movies()
authorities = Cinegraph.Cultural.list_authorities()
lists = Cinegraph.Cultural.list_curated_lists()
cri_scores = Cinegraph.Repo.all(Cinegraph.Cultural.CRIScore)

IO.puts("\n📊 Database Summary:")
IO.puts("   Movies: #{length(movies)}")
IO.puts("   Cultural Authorities: #{length(authorities)}")
IO.puts("   Curated Lists: #{length(lists)}")
IO.puts("   CRI Scores: #{length(cri_scores)}")

IO.puts("\n🎬 Movies in Database:")
Enum.each(movies, fn movie ->
  cri_score = Cinegraph.Cultural.get_latest_cri_score(movie.id)
  score_text = if cri_score, do: "CRI: #{Float.round(cri_score.score, 1)}", else: "No CRI"
  IO.puts("   - #{movie.title} (#{movie.release_date}) - #{score_text}")
end)

IO.puts("\n✨ UI Testing Data Ready!")
IO.puts("Start the server with: mix phx.server")
IO.puts("Visit: http://localhost:4000")
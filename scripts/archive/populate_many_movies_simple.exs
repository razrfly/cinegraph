# Script to populate database with 200+ popular movies for testing
# Run with: mix run populate_many_movies_simple.exs

Mix.Task.run("app.start")

IO.puts("🎬 Populating Database with Popular Movies")
IO.puts("=" <> String.duplicate("=", 60))

# Popular movie TMDB IDs - mix of classics and modern films
movie_ids = [
  238,   # The Godfather
  15,    # Citizen Kane
  289,   # Casablanca
  11216, # Cinema Paradiso
  637,   # Life Is Beautiful
  424,   # Schindler's List
  13,    # Forrest Gump
  680,   # Pulp Fiction
  155,   # The Dark Knight
  19404, # Dilwale Dulhania Le Jayenge
  129,   # Spirited Away
  372058, # Your Name
  389,   # 12 Angry Men
  598,   # City of God
  103,   # Taxi Driver
  27205, # Inception
  496243, # Parasite
  872585, # Oppenheimer
  346698, # Barbie
  361743, # Top Gun: Maverick
  545611, # Everything Everywhere All at Once
  370172, # No Time to Die
  438631, # Dune
  324857, # Spider-Verse
  284054, # Black Panther
  299534, # Avengers: Endgame
  475557, # Joker
  530915, # 1917
  466272, # Once Upon a Time in Hollywood
  398978, # The Irishman
  492188, # Marriage Story
  515001, # Jojo Rabbit
  546554, # Knives Out
  359724, # Ford v Ferrari
  331482, # Little Women
  76341,  # Mad Max: Fury Road
  335984, # Blade Runner 2049
  313369, # La La Land
  376867, # Moonlight
  329865, # Arrival
  338952, # Hell or High Water
  334533, # Manchester by the Sea
  360814, # Fences
  381284, # Hidden Figures
  324786, # Hacksaw Ridge
  383498, # Three Billboards
  400535, # Phantom Thread
  341013, # Call Me by Your Name
  399055, # The Shape of Water
  374720, # Darkest Hour
  419704, # Get Out
  391713, # Lady Bird
  399174, # The Post
  490132, # Green Book
  508442, # Roma
  424694, # Bohemian Rhapsody
  332562, # A Star Is Born
  472033, # Vice
  402900, # Can You Ever Forgive Me?
  # Classic additions
  120,   # LOTR: Fellowship
  121,   # LOTR: Two Towers
  122,   # LOTR: Return of the King
  111,   # Scarface
  85,    # Raiders of the Lost Ark
  89,    # Temple of Doom
  87,    # Last Crusade
  11,    # Star Wars
  1891,  # Empire Strikes Back
  1892,  # Return of the Jedi
  140607, # Force Awakens
  181808, # Last Jedi
  181812, # Rise of Skywalker
  348,   # Alien
  679,   # Aliens
  862,   # Toy Story
  863,   # Toy Story 2
  10193, # Toy Story 3
  301528, # Toy Story 4
  585,   # Monsters, Inc.
  14160, # Up
  12,    # Finding Nemo
  14836, # The Incredibles
  10681, # WALL-E
  135397, # Jurassic World
  329,   # Jurassic Park
  423,   # The Piano
  429,   # The Good, the Bad and the Ugly
  73,    # American Graffiti
  207,   # Dead Poets Society
  274,   # The Silence of the Lambs
  1422,  # The Departed
  807,   # Se7en
  550,   # Fight Club
  497,   # The Green Mile
  539,   # Psycho
  105,   # Back to the Future
  165,   # Back to the Future II
  166,   # Back to the Future III
  595,   # Goodfellas
  240,   # The Godfather: Part II
  1359,  # Amadeus
  755,   # Big Fish
  157336, # Interstellar
  49026,  # Dark Knight Rises
  49051,  # Hobbit: Unexpected Journey
  57158,  # Hobbit: Desolation of Smaug
  122917, # Hobbit: Battle of Five Armies
  99861,  # Avengers: Age of Ultron
  271110, # Captain America: Civil War
  284052, # Doctor Strange
  315635, # Spider-Man: Homecoming
  284053, # Thor: Ragnarok
  299536, # Avengers: Infinity War
  299537, # Captain Marvel
  420818, # The Lion King (2019)
  420817, # Aladdin (2019)
  447404, # Pokémon Detective Pikachu
  454626, # Sonic the Hedgehog
  508943, # Luca
  508947, # Turning Red
  618344, # Encanto
  718789, # The Super Mario Bros. Movie
  762441, # A Quiet Place Part II
  524434, # Eternals
  634649, # Spider-Man: No Way Home
  566525, # Shang-Chi
  505642, # Black Widow
  348350, # Solo: A Star Wars Story
  330457, # Rogue One
  429617, # The Greatest Showman
  # Additional variety
  177572, # Big Hero 6
  109445, # Frozen
  338958, # Moana
  354912, # Coco
  260513, # Incredibles 2
  508442, # Roma
  381288, # The Favourite
  408426, # The Ballad of Buster Scruggs
  348, # Alien
  550, # Fight Club
  680, # Pulp Fiction
  13, # Forrest Gump
  389, # 12 Angry Men
  129, # Spirited Away
  372058, # Your Name
  598, # City of God
  637, # Life Is Beautiful
  11216, # Cinema Paradiso
  19404, # Dilwale Dulhania Le Jayenge
  103, # Taxi Driver
  27205, # Inception
  155, # The Dark Knight
  238, # The Godfather
  15, # Citizen Kane
  289, # Casablanca
  424, # Schindler's List
  496243, # Parasite
  872585, # Oppenheimer
  346698, # Barbie
  # More recent hits
  545611, # Everything Everywhere All at Once
  675353, # Sonic the Hedgehog 2
  539681, # DC League of Super-Pets
  675353, # The Bad Guys
  718789, # The Super Mario Bros. Movie
  594767, # Shrek Forever After
  10193,  # Toy Story 3
  354912, # Coco
  260513, # Incredibles 2
  508943, # Luca
  508947, # Turning Red
  618344, # Encanto
  # International films for variety
  4935,   # Howl's Moving Castle
  128,    # Princess Mononoke
  10515,  # Ponyo
  378064, # A Silent Voice
  382322, # The Garden of Words
  492188, # Marriage Story
  515001, # Jojo Rabbit
  546554, # Knives Out
  399055, # The Shape of Water
  419704, # Get Out
  391713, # Lady Bird
  399174, # The Post
  490132, # Green Book
  508442, # Roma
  424694, # Bohemian Rhapsody
  332562, # A Star Is Born
]

# Remove duplicates and take first 150
unique_movie_ids = Enum.uniq(movie_ids) |> Enum.take(150)

IO.puts("🎯 Target: #{length(unique_movie_ids)} movies")

# Check current movie count
current_count = Cinegraph.Repo.aggregate(Cinegraph.Movies.Movie, :count)
IO.puts("📊 Current movies in database: #{current_count}")

if current_count >= 50 do
  IO.puts("✅ Already have sufficient movies for testing!")
else
  IO.puts("🚀 Adding movies...")
  
  # Sample movie data - in real implementation this would come from TMDB API
  sample_movies = [
    %{
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
    },
    %{
      tmdb_id: 15,
      title: "Citizen Kane",
      original_title: "Citizen Kane",
      release_date: ~D[1941-05-01],
      runtime: 119,
      overview: "Newspaper magnate Charles Foster Kane is taken from his mother as a boy.",
      tagline: "Some called him a hero... others called him a heel.",
      original_language: "en",
      budget: 839000,
      revenue: 1600000,
      status: "Released",
      poster_path: "/sav0jxhqiH0bPr2vZFU0Kjt2nZL.jpg"
    },
    %{
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
    },
    %{
      tmdb_id: 155,
      title: "The Dark Knight",
      original_title: "The Dark Knight",
      release_date: ~D[2008-07-18],
      runtime: 152,
      overview: "Batman raises the stakes in his war on crime with Lt. Jim Gordon and Harvey Dent.",
      tagline: "Welcome to a world without rules.",
      original_language: "en",
      budget: 185000000,
      revenue: 1004558444,
      status: "Released",
      poster_path: "/qJ2tW6WMUDux911r6m7haRef0WH.jpg"
    },
    %{
      tmdb_id: 680,
      title: "Pulp Fiction",
      original_title: "Pulp Fiction",
      release_date: ~D[1994-10-14],
      runtime: 154,
      overview: "A burger-loving hit man, his philosophical partner, and a washed-up boxer converge.",
      tagline: "Just because you are a character doesn't mean you have character.",
      original_language: "en",
      budget: 8000000,
      revenue: 214179088,
      status: "Released",
      poster_path: "/d5iIlFn5s0ImszYzBPb8JPIfbXD.jpg"
    }
  ]
  
  # Generate movies using the unique IDs
  generated_movies = Enum.map(6..length(unique_movie_ids), fn i ->
    year = Enum.random(1960..2024)
    month = Enum.random(1..12)
    day = Enum.random(1..28)
    
    %{
      tmdb_id: Enum.at(unique_movie_ids, i - 1),
      title: "Sample Movie #{i}",
      original_title: "Sample Movie #{i}",
      release_date: Date.new!(year, month, day),
      runtime: Enum.random(90..180),
      overview: "A compelling story about #{Enum.random(["love", "adventure", "mystery", "family", "friendship", "justice", "redemption"])} that explores the human condition.",
      tagline: Enum.random(["An unforgettable journey", "The story of a lifetime", "Nothing will ever be the same", "Prepare for the unexpected", "The ultimate test"]),
      original_language: Enum.random(["en", "fr", "es", "it", "de", "ja"]),
      budget: Enum.random(1000000..200000000),
      revenue: Enum.random(5000000..1000000000),
      status: "Released",
      poster_path: "/sample#{rem(i, 10)}.jpg"
    }
  end)
  
  all_movies = sample_movies ++ generated_movies
  
  # Insert movies in batches
  batch_size = 20
  total_inserted = 0
  
  all_movies
  |> Enum.chunk_every(batch_size)
  |> Enum.with_index()
  |> Enum.each(fn {batch, index} ->
    IO.write("Batch #{index + 1}: ")
    
    inserted_count = 
      batch
      |> Enum.reduce(0, fn movie_attrs, acc ->
        case Cinegraph.Movies.create_movie(movie_attrs) do
          {:ok, _movie} -> acc + 1
          {:error, _changeset} -> acc
        end
      end)
    
    IO.puts("#{inserted_count}/#{length(batch)} movies inserted")
    total_inserted + inserted_count
  end)
  
  IO.puts("✅ Movies population complete")
end

# Update final count
final_count = Cinegraph.Repo.aggregate(Cinegraph.Movies.Movie, :count)
IO.puts("🎬 Final movie count: #{final_count}")

# Seed authorities if needed
authorities_count = Cinegraph.Repo.aggregate(Cinegraph.Cultural.Authority, :count)
if authorities_count == 0 do
  IO.puts("🏛️ Seeding cultural authorities...")
  Cinegraph.Cultural.seed_authorities()
  IO.puts("✅ Authorities seeded")
end

# Add some movies to lists for variety
IO.puts("🎭 Adding movies to cultural lists...")

# Get some movies and lists
movies = Cinegraph.Movies.list_movies() |> Enum.take(30)
afi_list = Cinegraph.Repo.get_by(Cinegraph.Cultural.CuratedList, name: "AFI's 100 Years...100 Movies")
best_picture_list = Cinegraph.Repo.get_by(Cinegraph.Cultural.CuratedList, name: "Best Picture")

if afi_list && length(movies) > 0 do
  # Add first 15 movies to AFI list
  movies
  |> Enum.take(15)
  |> Enum.with_index(1)
  |> Enum.each(fn {movie, rank} ->
    case Cinegraph.Repo.get_by(Cinegraph.Cultural.MovieListItem, movie_id: movie.id, list_id: afi_list.id) do
      nil ->
        Cinegraph.Cultural.add_movie_to_list(movie.id, afi_list.id, %{
          rank: rank,
          notes: "Classic American film ##{rank}"
        })
      _existing -> :ok
    end
  end)
  
  IO.puts("✅ Added movies to AFI Top 100")
end

if best_picture_list && length(movies) > 10 do
  # Add some movies as award winners/nominees
  movies
  |> Enum.take(12)
  |> Enum.with_index()
  |> Enum.each(fn {movie, index} ->
    result = if rem(index, 3) == 0, do: "winner", else: "nominee"
    year = 1990 + index
    
    case Cinegraph.Repo.get_by(Cinegraph.Cultural.MovieListItem, movie_id: movie.id, list_id: best_picture_list.id) do
      nil ->
        Cinegraph.Cultural.add_movie_to_list(movie.id, best_picture_list.id, %{
          award_category: "Best Picture",
          award_result: result,
          year_added: year,
          notes: "#{year} Academy Awards"
        })
      _existing -> :ok
    end
  end)
  
  IO.puts("✅ Added award data")
end

# Calculate CRI scores for first 25 movies
IO.puts("📊 Calculating CRI scores...")
movies
|> Enum.take(25)
|> Enum.each(fn movie ->
  Cinegraph.Cultural.calculate_cri_score(movie.id)
end)

IO.puts("✅ CRI scores calculated")

IO.puts("\n🎉 Database Population Complete!")
IO.puts("Movies: #{Cinegraph.Repo.aggregate(Cinegraph.Movies.Movie, :count)}")
IO.puts("Authorities: #{Cinegraph.Repo.aggregate(Cinegraph.Cultural.Authority, :count)}")
IO.puts("Lists: #{Cinegraph.Repo.aggregate(Cinegraph.Cultural.CuratedList, :count)}")
IO.puts("CRI Scores: #{Cinegraph.Repo.aggregate(Cinegraph.Cultural.CRIScore, :count)}")
IO.puts("\n🌐 Visit: http://localhost:4000/movies")
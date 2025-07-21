# Script to populate database with 200+ popular movies for testing
# Run with: mix run populate_many_movies.exs

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
  top_gun_maverick = 361743,
  everything_everywhere = 545611,
  no_time_to_die = 370172,
  dune = 438631,
  spider_verse = 324857,
  black_panther = 284054,
  avengers_endgame = 299534,
  joker = 475557,
  530915, # 1917
  once_upon_a_time = 466272,
  the_irishman = 398978,
  marriage_story = 492188,
  jojo_rabbit = 515001,
  knives_out = 546554,
  ford_v_ferrari = 359724,
  little_women = 331482,
  mad_max_fury_road = 76341,
  blade_runner_2049 = 335984,
  la_la_land = 313369,
  moonlight = 376867,
  arrival = 329865,
  hell_or_high_water = 338952,
  manchester_by_the_sea = 334533,
  fences = 360814,
  hidden_figures = 381284,
  hacksaw_ridge = 324786,
  three_billboards = 383498,
  phantom_thread = 400535,
  call_me_by_your_name = 341013,
  shape_of_water = 399055,
  darkest_hour = 374720,
  dunkirk = 374720,
  get_out = 419704,
  lady_bird = 391713,
  the_post = 399174,
  green_book = 490132,
  roma = 508442,
  bohemian_rhapsody = 424694,
  a_star_is_born = 332562,
  vice = 472033,
  can_you_ever_forgive_me = 402900,
  # Classic additions
  120,   # The Lord of the Rings: The Fellowship of the Ring
  121,   # The Lord of the Rings: The Two Towers
  122,   # The Lord of the Rings: The Return of the King
  111,   # Scarface
  85,    # Raiders of the Lost Ark
  89,    # Indiana Jones and the Temple of Doom
  87,    # Indiana Jones and the Last Crusade
  11,    # Star Wars
  1891,  # The Empire Strikes Back
  1892,  # Return of the Jedi
  140607, # Star Wars: The Force Awakens
  181808, # Star Wars: The Last Jedi
  181812, # Star Wars: The Rise of Skywalker
  348,   # Alien
  679,   # Aliens
  2062,  # Rat Race
  862,   # Toy Story
  863,   # Toy Story 2
  10193, # Toy Story 3
  301528, # Toy Story 4
  585,   # Monsters, Inc.
  14160, # Up
  12,    # Finding Nemo
  14836, # The Incredibles
  10681, # WALL-E
  2062,  # Cars
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
  165,   # Back to the Future Part II
  166,  # Back to the Future Part III
  595,  # Goodfellas
  769,  # GoodFellas
  240,  # The Godfather: Part II
  1359, # Amadeus
  1891, # The Empire Strikes Back
  755,  # Big Fish
  157336, # Interstellar
  49026, # The Dark Knight Rises
  49051, # The Hobbit: An Unexpected Journey
  57158, # The Hobbit: The Desolation of Smaug
  122917, # The Hobbit: The Battle of the Five Armies
  99861, # Avengers: Age of Ultron
  271110, # Captain America: Civil War
  284052, # Doctor Strange
  315635, # Spider-Man: Homecoming
  284053, # Thor: Ragnarok
  284054, # Black Panther
  299536, # Avengers: Infinity War
  299537, # Captain Marvel
  299534, # Avengers: Endgame
  400160, # The SpongeBob Movie: Sponge on the Run
  420818, # The Lion King
  420817, # Aladdin
  447404, # Pokémon Detective Pikachu
  454626, # Sonic the Hedgehog
  508943, # Luca
  508947, # Turning Red
  618344, # Encanto
  539681, # DC League of Super-Pets
  585083, # Hotel Transylvania: Transformania
  675353, # Sonic the Hedgehog 2
  718789, # The Super Mario Bros. Movie
  762441, # A Quiet Place Part II
  524434, # Eternals
  634649, # Spider-Man: No Way Home
  566525, # Shang-Chi and the Legend of the Ten Rings
  505642, # Black Widow
  383498, # Three Billboards Outside Ebbing, Missouri
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
  # Add more varied genres
  181812, # Star Wars: The Rise of Skywalker
  348350, # Solo: A Star Wars Story
  330457, # Rogue One: A Star Wars Story
  429617, # The Greatest Showman
  284053, # Thor: Ragnarok
  338952, # Hell or High Water
  334533, # Manchester by the Sea
  360814, # Fences
  381284, # Hidden Figures
  324786, # Hacksaw Ridge
  400535, # Phantom Thread
  341013, # Call Me by Your Name
  # International films
  496243, # Parasite
  129, # Spirited Away
  372058, # Your Name
  637, # Life Is Beautiful
  11216, # Cinema Paradiso
  19404, # Dilwale Dulhania Le Jayenge
  598, # City of God
  680, # Pulp Fiction
]

# Remove duplicates and take first 200
unique_movie_ids = Enum.uniq(movie_ids) |> Enum.take(200)

IO.puts("🎯 Target: #{length(unique_movie_ids)} movies")

# Check current movie count
current_count = Cinegraph.Repo.aggregate(Cinegraph.Movies.Movie, :count)
IO.puts("📊 Current movies in database: #{current_count}")

if current_count >= 50 do
  IO.puts("✅ Already have sufficient movies for testing!")
else
  IO.puts("🚀 Adding movies...")
  
  # Sample movie data template - in real implementation this would come from TMDB API
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
      overview: "Newspaper magnate, Charles Foster Kane is taken from his mother as a boy and made the ward of a rich industrialist.",
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
      overview: "Batman raises the stakes in his war on crime. With the help of Lt. Jim Gordon and District Attorney Harvey Dent, Batman sets out to dismantle the remaining criminal organizations that plague the streets.",
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
      overview: "A burger-loving hit man, his philosophical partner, a drug-addled gangster's moll and a washed-up boxer converge in this sprawling, comedic crime caper.",
      tagline: "Just because you are a character doesn't mean you have character.",
      original_language: "en",
      budget: 8000000,
      revenue: 214179088,
      status: "Released",
      poster_path: "/d5iIlFn5s0ImszYzBPb8JPIfbXD.jpg"
    }
  ]
  
  # Generate more sample movies with variations
  generated_movies = Enum.map(6..200, fn i ->
    base_movie = Enum.random(sample_movies)
    year = Enum.random(1960..2024)
    month = Enum.random(1..12)
    day = Enum.random(1..28)
    
    %{
      tmdb_id: Enum.at(unique_movie_ids, i - 1) || (1000 + i),
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
  batch_size = 50
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
    total_inserted = total_inserted + inserted_count
  end)
  
  IO.puts("✅ Total movies inserted: #{total_inserted}")
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
movies = Cinegraph.Movies.list_movies() |> Enum.take(20)
afi_list = Cinegraph.Repo.get_by(Cinegraph.Cultural.CuratedList, name: "AFI's 100 Years...100 Movies")
best_picture_list = Cinegraph.Repo.get_by(Cinegraph.Cultural.CuratedList, name: "Best Picture")

if afi_list && length(movies) > 0 do
  # Add first 10 movies to AFI list
  movies
  |> Enum.take(10)
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

if best_picture_list && length(movies) > 5 do
  # Add some movies as award winners/nominees
  movies
  |> Enum.take(8)
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

# Calculate CRI scores for first 20 movies
IO.puts("📊 Calculating CRI scores...")
movies
|> Enum.take(20)
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
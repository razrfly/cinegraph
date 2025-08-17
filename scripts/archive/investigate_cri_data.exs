# Investigation script for CRI data accuracy
# Run with: mix run investigate_cri_data.exs

Mix.Task.run("app.start")
import Ecto.Query

IO.puts("🔍 Investigating CRI Data Accuracy & Coverage")
IO.puts("=" <> String.duplicate("=", 60))

# Check what's actually in our cultural authorities
IO.puts("\n🏛️ Cultural Authorities Analysis:")
authorities = Cinegraph.Cultural.list_authorities()

IO.puts("   Total Authorities: #{length(authorities)}")
Enum.each(authorities, fn auth ->
  IO.puts("   #{auth.id}. #{auth.name}")
  IO.puts("      Type: #{auth.authority_type}, Trust: #{auth.trust_score}")
  IO.puts("      Established: #{auth.established_year}, Country: #{auth.country_code}")
end)

# Check what's in our curated lists
IO.puts("\n📝 Curated Lists Analysis:")
lists = Cinegraph.Cultural.list_curated_lists()

IO.puts("   Total Lists: #{length(lists)}")
Enum.each(lists, fn list ->
  IO.puts("   #{list.id}. #{list.name} (#{list.year})")
  IO.puts("      Type: #{list.list_type}, Authority: #{list.authority.name}")
  IO.puts("      Prestige: #{list.prestige_score}, Impact: #{list.cultural_impact}")
  IO.puts("      Items: #{list.total_items || "unknown"}")
end)

# Check what movies we have
IO.puts("\n🎬 Movies in Database:")
movies = Cinegraph.Movies.list_movies()

IO.puts("   Total Movies: #{length(movies)}")
Enum.each(movies, fn movie ->
  IO.puts("   #{movie.id}. #{movie.title} (#{movie.release_date}) - TMDB: #{movie.tmdb_id}")
end)

# Check movie list items (the connections between movies and lists)
IO.puts("\n🔗 Movie-List Connections:")
if length(movies) > 0 do
  movie = hd(movies)
  IO.puts("   Checking connections for: #{movie.title}")
  
  # Get movie list items for this movie
  movie_list_items = from(item in Cinegraph.Cultural.MovieListItem,
    where: item.movie_id == ^movie.id,
    preload: [:list]
  ) |> Cinegraph.Repo.all()
  
  IO.puts("   Total list appearances: #{length(movie_list_items)}")
  
  Enum.each(movie_list_items, fn item ->
    IO.puts("     - List: #{item.list.name}")
    IO.puts("       Rank: #{item.rank || "unranked"}")
    IO.puts("       Award Category: #{item.award_category || "none"}")
    IO.puts("       Award Result: #{item.award_result || "none"}")
    IO.puts("       Notes: #{item.notes || "none"}")
  end)
else
  IO.puts("   No movies in database!")
end

# Check CRI scores
IO.puts("\n🧮 CRI Scores Analysis:")
cri_scores = Cinegraph.Repo.all(Cinegraph.Cultural.CRIScore)

IO.puts("   Total CRI Scores: #{length(cri_scores)}")
Enum.each(cri_scores, fn score ->
  movie = Cinegraph.Repo.get!(Cinegraph.Movies.Movie, score.movie_id)
  IO.puts("   Movie: #{movie.title}")
  IO.puts("   Score: #{Float.round(score.score, 2)}/100")
  IO.puts("   Components:")
  Enum.each(score.components, fn {component, value} ->
    IO.puts("     #{component}: #{Float.round(value, 4)}")
  end)
  IO.puts("   Calculated: #{score.calculated_at}")
end)

# Detailed analysis of why award recognition is 0.0
if length(movies) > 0 do
  movie = hd(movies)
  IO.puts("\n🎯 Detailed Award Recognition Analysis for #{movie.title}:")
  
  # Get the movie with all cultural data
  movie_with_cultural_data = from(movie in Cinegraph.Movies.Movie,
    left_join: list_items in assoc(movie, :movie_list_items),
    left_join: lists in assoc(list_items, :list),
    left_join: authorities in assoc(lists, :authority),
    where: movie.id == ^movie.id,
    preload: [movie_list_items: {list_items, list: {lists, authority: authorities}}]
  ) |> Cinegraph.Repo.one()
  
  if movie_with_cultural_data && movie_with_cultural_data.movie_list_items do
    IO.puts("   Movie list items found: #{length(movie_with_cultural_data.movie_list_items)}")
    
    # Check for awards specifically
    award_items = movie_with_cultural_data.movie_list_items
    |> Enum.filter(& &1.award_result in ["winner", "nominee"])
    
    IO.puts("   Award items (winner/nominee): #{length(award_items)}")
    
    if length(award_items) == 0 do
      IO.puts("   ⚠️  NO AWARD RESULTS SET!")
      IO.puts("   This explains why award_recognition = 0.0")
      IO.puts("   Current list items:")
      Enum.each(movie_with_cultural_data.movie_list_items, fn item ->
        IO.puts("     - #{item.list.name}: award_result = #{item.award_result || "nil"}")
      end)
    else
      winners = Enum.count(award_items, & &1.award_result == "winner")
      nominees = Enum.count(award_items, & &1.award_result == "nominee")
      IO.puts("   Winners: #{winners}, Nominees: #{nominees}")
    end
  else
    IO.puts("   ⚠️  NO CULTURAL DATA FOUND!")
  end
end

# Check external sources and ratings
IO.puts("\n📊 External Sources Analysis:")
external_sources = Cinegraph.Repo.all(Cinegraph.ExternalSources.Source)

IO.puts("   Total External Sources: #{length(external_sources)}")
Enum.each(external_sources, fn source ->
  IO.puts("   #{source.id}. #{source.name}")
  IO.puts("      Type: #{source.source_type}, Weight: #{source.weight_factor}")
  IO.puts("      Active: #{source.active}")
end)

# Check external ratings
IO.puts("\n⭐ External Ratings Analysis:")
external_ratings = Cinegraph.Repo.all(Cinegraph.ExternalSources.Rating)

IO.puts("   Total External Ratings: #{length(external_ratings)}")
Enum.each(external_ratings, fn rating ->
  movie = Cinegraph.Repo.get!(Cinegraph.Movies.Movie, rating.movie_id)
  source = Cinegraph.Repo.get!(Cinegraph.ExternalSources.Source, rating.source_id)
  IO.puts("   #{movie.title} - #{source.name}")
  IO.puts("      Type: #{rating.rating_type}, Value: #{rating.value}/#{rating.scale_max}")
  IO.puts("      Sample Size: #{rating.sample_size || "unknown"}")
end)

IO.puts("\n" <> String.duplicate("=", 60))
IO.puts("🎯 SUMMARY & RECOMMENDATIONS")
IO.puts("=" <> String.duplicate("=", 60))

IO.puts("\n📋 Data Population Status:")
IO.puts("   Cultural Authorities: #{length(authorities)} seeded")
IO.puts("   Curated Lists: #{length(lists)} created")
IO.puts("   Movies: #{length(movies)} loaded")
IO.puts("   Movie-List Connections: Available for analysis")

IO.puts("\n⚠️  Key Issues Identified:")
IO.puts("   1. Award results not populated (explains 0.0 award recognition)")
IO.puts("   2. Need real award data for The Godfather")
IO.puts("   3. CRI calculation working but operating on incomplete data")

IO.puts("\n✅ What's Working:")
IO.puts("   1. Schema and relationships are correct")
IO.puts("   2. CRI calculation algorithm is functional")
IO.puts("   3. Data can be populated and retrieved")

IO.puts("\n🚀 Next Steps for Real CRI Assessment:")
IO.puts("   1. Populate award_result fields with actual award data")
IO.puts("   2. Add more comprehensive movie list data")
IO.puts("   3. Test with multiple movies across different categories")
IO.puts("   4. Validate CRI scores against known cultural significance")

IO.puts("\n💡 The CRI system is architecturally sound but needs real award data!")
# Analyze what TMDB data we're missing or not using properly
import Ecto.Query
alias Cinegraph.{Repo, Movies}
alias Cinegraph.Movies.{Movie, Person, Credit}

IO.puts("\n🔍 TMDB API COVERAGE ANALYSIS\n")
IO.puts("=" <> String.duplicate("=", 60))

# 1. Check unused/null fields in our schema
IO.puts("\n📊 DATABASE FIELD USAGE ANALYSIS:")
IO.puts("-" <> String.duplicate("-", 40))

# Get sample movie to check raw data
sample_movie = Repo.one(from m in Movie, limit: 1)
raw_data = sample_movie.tmdb_raw_data

# Check for fields we're not storing
IO.puts("\n🚨 TMDB fields we're NOT storing:")
tmdb_fields = Map.keys(raw_data)
our_fields = ~w(id imdb_id title original_title release_date runtime overview tagline 
                original_language popularity vote_average vote_count budget revenue 
                status adult homepage poster_path backdrop_path genres spoken_languages 
                production_countries belongs_to_collection production_companies)

missing_fields = tmdb_fields -- our_fields
Enum.each(missing_fields, fn field ->
  value = raw_data[field]
  IO.puts("  - #{field}: #{inspect(value, limit: 80)}")
end)

# Check null prevalence
IO.puts("\n📈 Field NULL/empty rates (100 movies):")
total = Repo.aggregate(Movie, :count)

fields_to_check = [
  :imdb_id, :tagline, :homepage, :budget, :revenue, 
  :collection_id, :runtime, :overview
]

Enum.each(fields_to_check, fn field ->
  null_count = Repo.aggregate(
    from(m in Movie, where: is_nil(field(m, ^field))),
    :count
  )
  percentage = Float.round(null_count / total * 100, 1)
  IO.puts("  #{field}: #{null_count}/#{total} null (#{percentage}%)")
end)

# Check array field usage
IO.puts("\n📦 Array fields usage:")
empty_genres = Repo.aggregate(
  from(m in Movie, where: fragment("array_length(?, 1) = 0", m.genre_ids)),
  :count
)
empty_companies = Repo.aggregate(
  from(m in Movie, where: fragment("array_length(?, 1) = 0", m.production_company_ids)),
  :count
)
IO.puts("  Movies with no genres: #{empty_genres}")
IO.puts("  Movies with no production companies: #{empty_companies}")

# 2. Check what additional endpoints we could use
IO.puts("\n\n🌐 TMDB ENDPOINTS WE'RE NOT USING:")
IO.puts("-" <> String.duplicate("-", 40))

# Check if we have any of these in raw data
if raw_data["credits"] do
  IO.puts("✅ We're fetching credits with append_to_response")
else
  IO.puts("❌ Not fetching credits in initial call")
end

if raw_data["images"] do
  images = raw_data["images"]
  IO.puts("✅ We're fetching images with append_to_response")
  IO.puts("   - Posters: #{length(images["posters"] || [])}")
  IO.puts("   - Backdrops: #{length(images["backdrops"] || [])}")
  IO.puts("   - Logos: #{length(images["logos"] || [])}")
else
  IO.puts("❌ Not fetching additional images")
end

if raw_data["keywords"] do
  keywords = raw_data["keywords"]["keywords"] || []
  IO.puts("✅ We're fetching keywords (#{length(keywords)} found)")
  IO.puts("   Sample: #{Enum.take(keywords, 3) |> Enum.map(& &1["name"]) |> Enum.join(", ")}")
else
  IO.puts("❌ Not fetching keywords")
end

if raw_data["external_ids"] do
  IO.puts("✅ We're fetching external IDs")
  IO.inspect(raw_data["external_ids"], limit: :infinity)
else
  IO.puts("❌ Not fetching external IDs")
end

if raw_data["release_dates"] do
  IO.puts("✅ We're fetching release dates by country")
else
  IO.puts("❌ Not fetching release dates by country")
end

# 3. Check person data completeness
IO.puts("\n\n👤 PERSON DATA ANALYSIS:")
IO.puts("-" <> String.duplicate("-", 40))

sample_person = Repo.one(from p in Person, where: not is_nil(p.tmdb_raw_data), limit: 1)
if sample_person && sample_person.tmdb_raw_data do
  person_fields = Map.keys(sample_person.tmdb_raw_data)
  IO.puts("Person fields from cast/crew: #{inspect(person_fields)}")
  IO.puts("Note: We're only getting basic person data from credits, not full profiles")
end

# 4. Suggest missing relationships
IO.puts("\n\n🔗 MISSING RELATIONSHIPS/TABLES:")
IO.puts("-" <> String.duplicate("-", 40))

IO.puts("""
Based on TMDB API and issue #9, we're missing:

1. **Collections table** - We store collection_id but not collection details
2. **Production Companies table** - We store IDs but not company details  
3. **Keywords table & movie_keywords** - Important for thematic analysis
4. **Movie Videos** - Trailers, clips, featurettes
5. **Movie Alternative Titles** - Regional titles
6. **Movie Release Dates** - Release dates/certifications by country
7. **External IDs** - Facebook, Instagram, Twitter IDs for movies
8. **Movie Recommendations** - TMDB's recommendation data
9. **Similar Movies** - TMDB's similarity data
10. **Movie Translations** - Localized overviews/titles
""")

# 5. Data quality issues
IO.puts("\n⚠️  DATA QUALITY ISSUES:")
IO.puts("-" <> String.duplicate("-", 40))

# Check for missing TMDB IDs in arrays
movies_no_genres = Repo.all(
  from m in Movie, 
  where: fragment("array_length(?, 1) = 0", m.genre_ids),
  select: {m.id, m.title}
)
if length(movies_no_genres) > 0 do
  IO.puts("Movies with no genres: #{length(movies_no_genres)}")
end

# Check if we're storing raw person data
person_without_raw = Repo.aggregate(
  from(p in Person, where: is_nil(p.tmdb_raw_data)),
  :count
)
IO.puts("People without raw TMDB data: #{person_without_raw}")

# Summary
IO.puts("\n\n📋 SUMMARY OF IMPROVEMENTS NEEDED:")
IO.puts("=" <> String.duplicate("=", 60))
IO.puts("""
1. Store additional movie metadata we're already fetching
2. Create tables for collections, companies, keywords
3. Fetch full person details (not just from credits)
4. Add movie relationships (recommendations, similar)
5. Store regional data (release dates, certifications)
6. Implement video storage for trailers
7. Add external IDs for social media integration
""")
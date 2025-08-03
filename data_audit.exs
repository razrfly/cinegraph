# Comprehensive Data Audit Script
import Ecto.Query
alias Cinegraph.Repo
alias Cinegraph.Movies.{Movie, Genre, Keyword, Credit, ProductionCompany, Person}
alias Cinegraph.ExternalSources.Rating

IO.puts("=== CINEGRAPH DATA AUDIT ===")
IO.puts("Generated: #{DateTime.utc_now()}\n")

# 1. Basic Statistics
IO.puts("## 1. BASIC IMPORT STATISTICS")
movie_count = Repo.aggregate(Movie, :count)
person_count = Repo.aggregate(Person, :count)
genre_count = Repo.aggregate(Genre, :count)
keyword_count = Repo.aggregate(Keyword, :count)
company_count = Repo.aggregate(ProductionCompany, :count)

IO.puts("Total movies: #{movie_count}")
IO.puts("Total people: #{person_count}")
IO.puts("Total genres: #{genre_count}")
IO.puts("Total keywords: #{keyword_count}")
IO.puts("Total production companies: #{company_count}")

# 2. Movie Quality Analysis
IO.puts("\n## 2. MOVIE QUALITY ANALYSIS")

# Movies with missing key data
no_poster = Repo.one(from m in Movie, where: is_nil(m.poster_path), select: count(m.id))
no_overview = Repo.one(from m in Movie, where: is_nil(m.overview) or m.overview == "", select: count(m.id))
no_release_date = Repo.one(from m in Movie, where: is_nil(m.release_date), select: count(m.id))
no_runtime = Repo.one(from m in Movie, where: is_nil(m.runtime) or m.runtime == 0, select: count(m.id))
no_genres = Repo.one(
  from m in Movie,
  left_join: mg in "movie_genres", on: m.id == mg.movie_id,
  where: is_nil(mg.movie_id),
  select: count(m.id, :distinct)
)

IO.puts("Movies without poster: #{no_poster} (#{Float.round(no_poster/movie_count*100, 1)}%)")
IO.puts("Movies without overview: #{no_overview} (#{Float.round(no_overview/movie_count*100, 1)}%)")
IO.puts("Movies without release date: #{no_release_date} (#{Float.round(no_release_date/movie_count*100, 1)}%)")
IO.puts("Movies without runtime: #{no_runtime} (#{Float.round(no_runtime/movie_count*100, 1)}%)")
IO.puts("Movies without genres: #{no_genres} (#{Float.round(no_genres/movie_count*100, 1)}%)")

# Popularity and vote analysis
popularity_stats = Repo.one(
  from m in Movie,
  select: %{
    avg: avg(m.popularity),
    min: min(m.popularity),
    max: max(m.popularity),
    zero_count: sum(fragment("CASE WHEN ? = 0 THEN 1 ELSE 0 END", m.popularity))
  }
)

vote_stats = Repo.one(
  from m in Movie,
  select: %{
    avg: avg(m.vote_average),
    min: min(m.vote_average),
    max: max(m.vote_average),
    zero_count: sum(fragment("CASE WHEN ? = 0 THEN 1 ELSE 0 END", m.vote_average)),
    no_votes: sum(fragment("CASE WHEN ? = 0 THEN 1 ELSE 0 END", m.vote_count))
  }
)

IO.puts("\nPopularity Statistics:")
IO.puts("  Average: #{Float.round(popularity_stats.avg || 0, 2)}")
IO.puts("  Min: #{popularity_stats.min || 0}")
IO.puts("  Max: #{popularity_stats.max || 0}")
IO.puts("  Zero popularity: #{popularity_stats.zero_count || 0}")

IO.puts("\nVote Statistics:")
IO.puts("  Average rating: #{Float.round(vote_stats.avg || 0, 2)}")
IO.puts("  Movies with no votes: #{vote_stats.no_votes || 0}")

# 3. Low Quality Movies
IO.puts("\n## 3. LOW QUALITY MOVIE ANALYSIS")

# Movies that might be considered "garbage"
low_quality_movies = Repo.all(
  from m in Movie,
  where: (is_nil(m.poster_path) or m.popularity < 0.5) and m.vote_count < 10,
  select: %{
    id: m.id,
    title: m.title,
    popularity: m.popularity,
    vote_count: m.vote_count,
    has_poster: not is_nil(m.poster_path)
  },
  limit: 10
)

IO.puts("Sample of potentially low-quality movies:")
Enum.each(low_quality_movies, fn movie ->
  IO.puts("  - #{movie.title}: popularity=#{movie.popularity}, votes=#{movie.vote_count}, poster=#{movie.has_poster}")
end)

low_quality_count = Repo.one(
  from m in Movie,
  where: (is_nil(m.poster_path) or m.popularity < 0.5) and m.vote_count < 10,
  select: count(m.id)
)
IO.puts("Total potentially low-quality movies: #{low_quality_count} (#{Float.round(low_quality_count/movie_count*100, 1)}%)")

# 4. Cast/Crew Quality Analysis
IO.puts("\n## 4. CAST/CREW QUALITY ANALYSIS")

# People statistics
no_profile = Repo.one(from p in Person, where: is_nil(p.profile_path), select: count(p.id))
zero_popularity = Repo.one(from p in Person, where: p.popularity == 0.0, select: count(p.id))

IO.puts("People without profile photo: #{no_profile} (#{Float.round(no_profile/person_count*100, 1)}%)")
IO.puts("People with zero popularity: #{zero_popularity} (#{Float.round(zero_popularity/person_count*100, 1)}%)")

# Cast member appearance counts
cast_appearances = Repo.all(
  from c in Credit,
  where: c.credit_type == "cast",
  group_by: c.person_id,
  select: %{person_id: c.person_id, count: count(c.id)},
  order_by: [desc: count(c.id)],
  limit: 10
)

IO.puts("\nTop 10 most frequent cast members:")
Enum.each(cast_appearances, fn appearance ->
  person = Repo.get(Person, appearance.person_id)
  if person do
    IO.puts("  - #{person.name}: #{appearance.count} movies (popularity: #{person.popularity})")
  end
end)

# 5. Data Completeness
IO.puts("\n## 5. DATA COMPLETENESS BY TABLE")

# Junction table completeness
movie_genres_count = Repo.one(from mg in "movie_genres", select: count())
movie_keywords_count = Repo.one(from mk in "movie_keywords", select: count())
movie_companies_count = Repo.one(from mc in "movie_production_companies", select: count())
movie_credits_count = Repo.aggregate(Credit, :count)
# Check if movie_videos table exists
movie_videos_count = try do
  Repo.one(from mv in "movie_videos", select: count())
rescue
  _ -> 0
end
ratings_count = Repo.aggregate(Rating, :count)

IO.puts("Movie-Genre relationships: #{movie_genres_count}")
IO.puts("Movie-Keyword relationships: #{movie_keywords_count}")
IO.puts("Movie-Company relationships: #{movie_companies_count}")
IO.puts("Movie credits: #{movie_credits_count}")
IO.puts("Movie videos: #{movie_videos_count}")
IO.puts("External ratings: #{ratings_count}")

# Average relationships per movie
IO.puts("\nAverage relationships per movie:")
IO.puts("  Genres: #{Float.round(movie_genres_count/movie_count, 2)}")
IO.puts("  Keywords: #{Float.round(movie_keywords_count/movie_count, 2)}")
IO.puts("  Companies: #{Float.round(movie_companies_count/movie_count, 2)}")
IO.puts("  Credits: #{Float.round(movie_credits_count/movie_count, 2)}")
IO.puts("  Videos: #{Float.round(movie_videos_count/movie_count, 2)}")

# 6. External Data Integration
IO.puts("\n## 6. EXTERNAL DATA INTEGRATION")

with_omdb = Repo.one(from m in Movie, where: not is_nil(m.omdb_data), select: count(m.id))
with_imdb_id = Repo.one(from m in Movie, where: not is_nil(m.imdb_id), select: count(m.id))

IO.puts("Movies with OMDb data: #{with_omdb} (#{Float.round(with_omdb/movie_count*100, 1)}%)")
IO.puts("Movies with IMDb ID: #{with_imdb_id} (#{Float.round(with_imdb_id/movie_count*100, 1)}%)")

# Rating types breakdown
rating_breakdown = Repo.all(
  from r in Rating,
  group_by: r.rating_type,
  select: {r.rating_type, count(r.id)}
)

IO.puts("\nExternal ratings breakdown:")
Enum.each(rating_breakdown, fn {type, count} ->
  IO.puts("  #{type}: #{count}")
end)

# 7. Feature Table Analysis
IO.puts("\n## 7. FEATURE TABLE ANALYSIS")

# Check for connection/relationship tables
tables = Repo.query!("SELECT tablename FROM pg_tables WHERE schemaname = 'public' ORDER BY tablename").rows
feature_tables = Enum.filter(tables, fn [name] -> 
  String.contains?(name, ["connection", "relation", "degree", "collab"])
end)

IO.puts("Feature-related tables found:")
Enum.each(feature_tables, fn [table] ->
  count = Repo.query!("SELECT COUNT(*) FROM #{table}").rows |> hd |> hd
  IO.puts("  #{table}: #{count} rows")
end)

# 8. Missing Data Summary
IO.puts("\n## 8. CRITICAL MISSING DATA")

# Check for empty essential fields
critical_missing = %{
  "Movies without any credits" => Repo.one(
    from m in Movie,
    left_join: c in Credit, on: m.id == c.movie_id,
    where: is_nil(c.id),
    select: count(m.id, :distinct)
  ),
  "Movies without production companies" => Repo.one(
    from m in Movie,
    left_join: mpc in "movie_production_companies", on: m.id == mpc.movie_id,
    where: is_nil(mpc.movie_id),
    select: count(m.id, :distinct)
  ),
  "Movies without keywords" => Repo.one(
    from m in Movie,
    left_join: mk in "movie_keywords", on: m.id == mk.movie_id,
    where: is_nil(mk.movie_id),
    select: count(m.id, :distinct)
  )
}

Enum.each(critical_missing, fn {desc, count} ->
  IO.puts("#{desc}: #{count} (#{Float.round(count/movie_count*100, 1)}%)")
end)

IO.puts("\n=== END OF AUDIT ===")
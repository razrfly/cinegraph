#!/usr/bin/env elixir

# Script to audit what data is REALLY being collected vs test data

import Ecto.Query

alias Cinegraph.{Repo, Movies, Cultural, ExternalSources}
alias Cinegraph.Movies.{Movie, Person, Credit, Keyword, MovieVideo, MovieReleaseDate, Collection, ProductionCompany}
alias Cinegraph.Cultural.{Authority, CuratedList, MovieListItem}
alias Cinegraph.ExternalSources.{Rating, Source, Recommendation}

IO.puts "\n=== CINEGRAPH DATA COLLECTION AUDIT ===\n"

# 1. Basic Movie Data
IO.puts "1. BASIC MOVIE DATA"
IO.puts "==================="

movie_count = Repo.aggregate(Movie, :count)
IO.puts "Total movies: #{movie_count}"

if movie_count > 0 do
  # Check for real movie data
  movies_with_data = Repo.all(
    from m in Movie,
    select: %{
      id: m.id,
      title: m.title,
      has_budget: not is_nil(m.budget),
      has_revenue: not is_nil(m.revenue),
      has_collection: not is_nil(m.collection_id),
      has_external_ids: fragment("? != '{}'::jsonb", m.external_ids),
      has_images: fragment("? != '{}'::jsonb", m.images),
      has_keywords: fragment("EXISTS (SELECT 1 FROM movie_keywords mk WHERE mk.movie_id = ?)", m.id),
      has_videos: fragment("EXISTS (SELECT 1 FROM movie_videos mv WHERE mv.movie_id = ?)", m.id),
      has_release_dates: fragment("EXISTS (SELECT 1 FROM movie_release_dates mrd WHERE mrd.movie_id = ?)", m.id)
    },
    limit: 10
  )
  
  IO.puts "\nSample of movie data completeness (first 10):"
  for movie <- movies_with_data do
    IO.puts "  - #{movie.title}:"
    IO.puts "    Budget/Revenue: #{movie.has_budget}/#{movie.has_revenue}"
    IO.puts "    Collection: #{movie.has_collection}"
    IO.puts "    External IDs: #{movie.has_external_ids}"
    IO.puts "    Images populated: #{movie.has_images}"
    IO.puts "    Has keywords: #{movie.has_keywords}"
    IO.puts "    Has videos: #{movie.has_videos}"
    IO.puts "    Has release dates: #{movie.has_release_dates}"
  end
  
  # Check external IDs content
  sample_external_ids = Repo.all(
    from m in Movie,
    where: fragment("? != '{}'::jsonb", m.external_ids),
    select: {m.title, m.external_ids},
    limit: 3
  )
  
  if length(sample_external_ids) > 0 do
    IO.puts "\nSample external IDs:"
    for {title, ids} <- sample_external_ids do
      IO.puts "  #{title}: #{inspect(ids)}"
    end
  end
end

# 2. Keywords Data
IO.puts "\n\n2. KEYWORDS DATA"
IO.puts "=================="

keyword_count = Repo.aggregate(Keyword, :count)
IO.puts "Total keywords: #{keyword_count}"

if keyword_count > 0 do
  movie_keyword_count = Repo.one(
    from mk in "movie_keywords",
    select: count(mk.id)
  )
  IO.puts "Total movie-keyword associations: #{movie_keyword_count}"
  
  # Sample keywords
  sample_keywords = Repo.all(
    from k in Keyword,
    join: mk in "movie_keywords", on: mk.keyword_id == k.id,
    join: m in Movie, on: m.id == mk.movie_id,
    select: {m.title, k.name},
    limit: 10
  )
  
  IO.puts "\nSample keywords:"
  for {title, keyword} <- sample_keywords do
    IO.puts "  #{title} -> #{keyword}"
  end
end

# 3. Videos Data
IO.puts "\n\n3. VIDEOS DATA"
IO.puts "==============="

video_count = Repo.aggregate(MovieVideo, :count)
IO.puts "Total videos: #{video_count}"

if video_count > 0 do
  video_types = Repo.all(
    from v in MovieVideo,
    group_by: v.type,
    select: {v.type, count(v.id)}
  )
  
  IO.puts "\nVideo types:"
  for {type, count} <- video_types do
    IO.puts "  #{type}: #{count}"
  end
  
  # Sample videos
  sample_videos = Repo.all(
    from v in MovieVideo,
    join: m in Movie, on: m.id == v.movie_id,
    where: v.type == "Trailer",
    select: {m.title, v.name, v.site, v.key},
    limit: 5
  )
  
  IO.puts "\nSample trailers:"
  for {title, name, site, key} <- sample_videos do
    IO.puts "  #{title}: #{name} (#{site}: #{key})"
  end
end

# 4. Release Dates Data
IO.puts "\n\n4. RELEASE DATES DATA"
IO.puts "====================="

release_date_count = Repo.aggregate(MovieReleaseDate, :count)
IO.puts "Total release date entries: #{release_date_count}"

if release_date_count > 0 do
  # Countries with certifications
  cert_countries = Repo.all(
    from rd in MovieReleaseDate,
    where: not is_nil(rd.certification) and rd.certification != "",
    group_by: rd.country_code,
    select: {rd.country_code, count(rd.id)},
    order_by: [desc: count(rd.id)],
    limit: 10
  )
  
  IO.puts "\nTop countries with certifications:"
  for {country, count} <- cert_countries do
    IO.puts "  #{country}: #{count} movies"
  end
end

# 5. Authority & Award Data
IO.puts "\n\n5. AUTHORITY & AWARD DATA"
IO.puts "========================="

authority_count = Repo.aggregate(Authority, :count)
IO.puts "Total authorities: #{authority_count}"

if authority_count > 0 do
  authorities = Repo.all(
    from a in Authority,
    select: {a.name, a.authority_type, a.category, a.trust_score}
  )
  
  IO.puts "\nAuthorities:"
  for {name, type, category, trust} <- authorities do
    IO.puts "  - #{name} (#{type}, #{category || "N/A"}) - Trust: #{trust}"
  end
  
  # Check for award authorities specifically
  award_authorities = Repo.all(
    from a in Authority,
    where: a.authority_type == "award",
    select: a.name
  )
  
  IO.puts "\nAward authorities: #{inspect(award_authorities)}"
end

# 6. Curated Lists (including awards)
IO.puts "\n\n6. CURATED LISTS & AWARDS"
IO.puts "=========================="

list_count = Repo.aggregate(CuratedList, :count)
IO.puts "Total curated lists: #{list_count}"

if list_count > 0 do
  # Check list types
  list_types = Repo.all(
    from cl in CuratedList,
    group_by: cl.list_type,
    select: {cl.list_type, count(cl.id)}
  )
  
  IO.puts "\nList types:"
  for {type, count} <- list_types do
    IO.puts "  #{type}: #{count}"
  end
  
  # Award lists specifically
  award_lists = Repo.all(
    from cl in CuratedList,
    join: a in Authority, on: a.id == cl.authority_id,
    where: cl.list_type == "award" or a.authority_type == "award",
    select: {cl.name, cl.year, a.name},
    limit: 10
  )
  
  IO.puts "\nAward lists:"
  for {list_name, year, auth_name} <- award_lists do
    IO.puts "  - #{list_name} (#{year}) by #{auth_name}"
  end
  
  # Movies in lists
  movie_list_count = Repo.aggregate(MovieListItem, :count)
  IO.puts "\nTotal movie-list associations: #{movie_list_count}"
  
  # Sample movie appearances
  sample_appearances = Repo.all(
    from mli in MovieListItem,
    join: m in Movie, on: m.id == mli.movie_id,
    join: cl in CuratedList, on: cl.id == mli.list_id,
    join: a in Authority, on: a.id == cl.authority_id,
    select: {m.title, cl.name, cl.year, a.name, mli.rank, mli.award_category},
    limit: 10
  )
  
  IO.puts "\nSample movie list appearances:"
  for {title, list, year, auth, rank, category} <- sample_appearances do
    IO.puts "  - #{title} in #{list} (#{year}) by #{auth}"
    if rank, do: IO.puts("    Rank: #{rank}")
    if category, do: IO.puts("    Category: #{category}")
  end
end

# 7. External Ratings
IO.puts "\n\n7. EXTERNAL RATINGS"
IO.puts "==================="

rating_count = Repo.aggregate(Rating, :count)
IO.puts "Total external ratings: #{rating_count}"

if rating_count > 0 do
  # Check sources
  source_count = Repo.aggregate(Source, :count)
  IO.puts "Total rating sources: #{source_count}"
  
  sources = Repo.all(
    from s in Source,
    select: {s.name, s.source_type}
  )
  
  IO.puts "\nRating sources:"
  for {name, type} <- sources do
    IO.puts "  - #{name} (#{type})"
  end
  
  # Ratings by source
  ratings_by_source = Repo.all(
    from r in Rating,
    join: s in Source, on: s.id == r.source_id,
    group_by: s.name,
    select: {s.name, count(r.id), avg(r.rating)},
    order_by: [desc: count(r.id)]
  )
  
  IO.puts "\nRatings by source:"
  for {source, count, avg_rating} <- ratings_by_source do
    IO.puts "  #{source}: #{count} ratings (avg: #{Float.round(avg_rating || 0, 2)})"
  end
  
  # Sample ratings
  sample_ratings = Repo.all(
    from r in Rating,
    join: m in Movie, on: m.id == r.movie_id,
    join: s in Source, on: s.id == r.source_id,
    select: {m.title, s.name, r.rating, r.review_count},
    limit: 10
  )
  
  IO.puts "\nSample ratings:"
  for {title, source, rating, reviews} <- sample_ratings do
    IO.puts "  #{title} - #{source}: #{rating} (#{reviews || 0} reviews)"
  end
end

# 8. Collections & Production Companies
IO.puts "\n\n8. COLLECTIONS & PRODUCTION COMPANIES"
IO.puts "====================================="

collection_count = Repo.aggregate(Collection, :count)
IO.puts "Total collections: #{collection_count}"

if collection_count > 0 do
  # Sample collections
  sample_collections = Repo.all(
    from c in Collection,
    select: {c.name, c.tmdb_id},
    limit: 5
  )
  
  IO.puts "\nSample collections:"
  for {name, tmdb_id} <- sample_collections do
    IO.puts "  - #{name} (TMDB: #{tmdb_id})"
  end
end

company_count = Repo.aggregate(ProductionCompany, :count)
IO.puts "\nTotal production companies: #{company_count}"

if company_count > 0 do
  # Sample companies
  sample_companies = Repo.all(
    from pc in ProductionCompany,
    select: {pc.name, pc.origin_country},
    limit: 5
  )
  
  IO.puts "\nSample production companies:"
  for {name, country} <- sample_companies do
    IO.puts "  - #{name} (#{country || "Unknown"})"
  end
end

# 9. People Data
IO.puts "\n\n9. PEOPLE DATA"
IO.puts "==============="

person_count = Repo.aggregate(Person, :count)
IO.puts "Total people: #{person_count}"

if person_count > 0 do
  # Check for full person data
  people_with_data = Repo.all(
    from p in Person,
    select: %{
      name: p.name,
      has_bio: not is_nil(p.biography),
      has_birthday: not is_nil(p.birthday),
      has_raw_data: not is_nil(p.tmdb_raw_data) and fragment("? != '{}'::jsonb", p.tmdb_raw_data)
    },
    limit: 10
  )
  
  IO.puts "\nPeople data completeness (first 10):"
  for person <- people_with_data do
    IO.puts "  - #{person.name}: Bio: #{person.has_bio}, Birthday: #{person.has_birthday}, Raw data: #{person.has_raw_data}"
  end
end

# 10. Summary
IO.puts "\n\n=== SUMMARY ==="
IO.puts "==============="

IO.puts """
Data Collection Status:
- Movies: #{movie_count}
- Keywords: #{keyword_count}
- Videos: #{video_count}
- Release Dates: #{release_date_count}
- Authorities: #{authority_count}
- Curated Lists: #{list_count}
- External Ratings: #{rating_count}
- Collections: #{collection_count}
- Production Companies: #{company_count}
- People: #{person_count}

This audit shows what data is ACTUALLY in the database.
Compare this with the goals in GitHub issue #10 to see gaps.
"""
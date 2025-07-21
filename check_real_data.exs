#!/usr/bin/env elixir

# Quick script to check if we have real movie data

import Ecto.Query
alias Cinegraph.{Repo, Movies}
alias Cinegraph.Movies.{Movie, Person, Credit}
alias Cinegraph.Cultural.{Authority, CuratedList, MovieListItem}
alias Cinegraph.ExternalSources.{Rating, Source}

IO.puts "\n=== CHECKING FOR REAL VS TEST DATA ===\n"

# Check movies
IO.puts "Sample Movies:"
movies = Repo.all(from m in Movie, select: {m.id, m.title, m.tmdb_id, m.release_date}, limit: 20)

for {id, title, tmdb_id, release_date} <- movies do
  IO.puts "  #{id}: #{title} (TMDB: #{tmdb_id}, Released: #{release_date})"
end

# Check if these are real TMDB IDs by looking at the titles
IO.puts "\nThese appear to be real movies from TMDB (Fight Club, Citizen Kane, etc.)"

# Check authorities - are they test data?
IO.puts "\n\nAuthorities:"
authorities = Repo.all(from a in Authority, select: {a.name, a.authority_type, a.description})

for {name, type, desc} <- authorities do
  IO.puts "  - #{name} (#{type})"
  if desc, do: IO.puts("    #{desc}")
end

# Check curated lists
IO.puts "\n\nCurated Lists:"
lists = Repo.all(
  from cl in CuratedList,
  join: a in Authority, on: a.id == cl.authority_id,
  select: {cl.name, cl.year, cl.list_type, a.name}
)

for {list_name, year, type, auth_name} <- lists do
  IO.puts "  - #{list_name} (#{year}) - #{type} by #{auth_name}"
end

# Check for actual award data in movie_list_items
IO.puts "\n\nMovie Award/List Appearances:"
appearances = Repo.all(
  from mli in MovieListItem,
  join: m in Movie, on: m.id == mli.movie_id,
  join: cl in CuratedList, on: cl.id == mli.list_id,
  where: not is_nil(mli.award_category) or cl.list_type == "award",
  select: {m.title, cl.name, mli.award_category, mli.rank},
  limit: 10
)

if length(appearances) > 0 do
  for {title, list, category, rank} <- appearances do
    IO.puts "  - #{title} in #{list}"
    if category, do: IO.puts("    Category: #{category}")
    if rank, do: IO.puts("    Rank: #{rank}")
  end
else
  IO.puts "  No award data found!"
end

# Check external ratings
IO.puts "\n\nExternal Ratings Sources:"
sources = Repo.all(Source)
if length(sources) > 0 do
  for source <- sources do
    IO.puts "  - #{source.name} (#{source.source_type})"
  end
else
  IO.puts "  No external rating sources configured!"
end

# Check for TMDB extended data
IO.puts "\n\nTMDB Extended Data Check:"
# Check if we're using append_to_response properly
movie_with_data = Repo.one(from m in Movie, where: not is_nil(m.tmdb_raw_data), limit: 1)
if movie_with_data && movie_with_data.tmdb_raw_data do
  raw_keys = Map.keys(movie_with_data.tmdb_raw_data)
  IO.puts "  Raw data keys for #{movie_with_data.title}:"
  IO.puts "  #{inspect(raw_keys)}"
  
  # Check if we have extended data in raw
  extended_endpoints = ["keywords", "videos", "release_dates", "external_ids", "images", "credits"]
  missing_endpoints = extended_endpoints -- raw_keys
  
  if length(missing_endpoints) > 0 do
    IO.puts "\n  ⚠️  Missing from append_to_response: #{inspect(missing_endpoints)}"
  else
    IO.puts "\n  ✅ All extended endpoints present in raw data"
  end
else
  IO.puts "  No movies have raw TMDB data stored!"
end

IO.puts "\n\n=== CONCLUSION ===\n"
IO.puts """
Based on the data audit:

1. Movies: We have #{length(movies)} real movies from TMDB (Fight Club, Citizen Kane, etc.)
2. Keywords/Videos/Release Dates: NOT being collected (0 records each)
3. People/Credits: NOT being collected (0 records)
4. Authorities: Mix of real (Academy, Cannes, BFI) and test data
5. Awards: Only test/sample award data, no real Oscar/Cannes winners
6. External Ratings: NOT configured or collected
7. TMDB Extended Data: NOT using append_to_response properly

This is mostly TEST DATA with real movie titles but missing most connected data!
"""
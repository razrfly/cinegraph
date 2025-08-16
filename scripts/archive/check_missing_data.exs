# Quick check for what additional data TMDB provides
import Ecto.Query
alias Cinegraph.Repo
alias Cinegraph.Movies.Movie

# Get a sample movie's raw data
sample = Repo.one(from m in Movie, limit: 1)
raw = sample.tmdb_raw_data

IO.puts("\n🎬 Sample Movie: #{sample.title}")
IO.puts("\n📋 TMDB provides these additional data endpoints:")

# Check what we got from append_to_response
if raw["keywords"] do
  keywords = raw["keywords"]["keywords"] || []
  IO.puts("\n✅ Keywords (#{length(keywords)}):")
  Enum.take(keywords, 5) |> Enum.each(fn k -> 
    IO.puts("   - #{k["name"]} (ID: #{k["id"]})")
  end)
end

if raw["videos"] do
  videos = raw["videos"]["results"] || []
  IO.puts("\n✅ Videos (#{length(videos)}):")
  Enum.take(videos, 3) |> Enum.each(fn v -> 
    IO.puts("   - #{v["name"]} (#{v["type"]}, #{v["site"]})")
  end)
else
  IO.puts("\n❌ No videos data (not in append_to_response)")
end

if raw["release_dates"] do
  countries = raw["release_dates"]["results"] || []
  IO.puts("\n✅ Release dates by country (#{length(countries)} countries)")
  Enum.take(countries, 3) |> Enum.each(fn c ->
    releases = c["release_dates"] || []
    first_release = List.first(releases) || %{}
    IO.puts("   - #{c["iso_3166_1"]}: #{first_release["release_date"]} (Cert: #{first_release["certification"]})")
  end)
end

if raw["recommendations"] do
  recs = raw["recommendations"]["results"] || []
  IO.puts("\n❌ Recommendations data exists but not fetched (#{length(recs)} movies)")
else
  IO.puts("\n❌ No recommendations (not in append_to_response)")
end

if raw["similar"] do
  similar = raw["similar"]["results"] || []
  IO.puts("\n❌ Similar movies data exists but not fetched (#{length(similar)} movies)")
else
  IO.puts("\n❌ No similar movies (not in append_to_response)")
end

# Check external IDs
if raw["external_ids"] do
  IO.puts("\n✅ External IDs:")
  Map.keys(raw["external_ids"]) |> Enum.each(fn key ->
    value = raw["external_ids"][key]
    if value, do: IO.puts("   - #{key}: #{value}")
  end)
end

# Check images
if raw["images"] do
  images = raw["images"]
  IO.puts("\n✅ Additional Images:")
  IO.puts("   - Posters: #{length(images["posters"] || [])}")
  IO.puts("   - Backdrops: #{length(images["backdrops"] || [])}")
  IO.puts("   - Logos: #{length(images["logos"] || [])}")
end

# Check what fields we're not using
IO.puts("\n\n⚠️  Fields in TMDB data we're ignoring:")
unused_fields = ["credits", "images", "keywords", "external_ids", "release_dates", "videos", 
                 "recommendations", "similar", "belongs_to_collection"]
stored_fields = Map.keys(raw) -- unused_fields
IO.puts("Stored in tmdb_raw_data but not extracted: #{inspect(stored_fields -- ["id"])}")
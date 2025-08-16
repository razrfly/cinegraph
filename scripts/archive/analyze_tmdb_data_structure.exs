# Analyze TMDB API response structure
alias Cinegraph.Services.TMDb
require Logger

IO.puts("\n🔍 ANALYZING TMDB API DATA STRUCTURE\n")
IO.puts("=" <> String.duplicate("=", 60))

# Test with a popular movie (Fight Club)
movie_id = 550

IO.puts("\n1️⃣ Basic Movie Data:")
IO.puts("-" <> String.duplicate("-", 40))

case TMDb.get_movie(movie_id) do
  {:ok, basic_data} ->
    IO.puts("Fields returned: #{inspect(Map.keys(basic_data) |> Enum.sort())}")
    IO.puts("\nSample values:")
    IO.puts("  - id: #{basic_data["id"]}")
    IO.puts("  - title: #{basic_data["title"]}")
    IO.puts("  - budget: #{basic_data["budget"]}")
    IO.puts("  - revenue: #{basic_data["revenue"]}")
    
  {:error, reason} ->
    IO.puts("❌ Failed to fetch basic data: #{inspect(reason)}")
end

IO.puts("\n\n2️⃣ Comprehensive Movie Data (with append_to_response):")
IO.puts("-" <> String.duplicate("-", 40))

case TMDb.get_movie_comprehensive(movie_id) do
  {:ok, comprehensive_data} ->
    IO.puts("All top-level fields: #{inspect(Map.keys(comprehensive_data) |> Enum.sort())}")
    
    # Check what additional data we got
    IO.puts("\n📦 Additional data received:")
    
    if comprehensive_data["credits"] do
      cast_count = length(comprehensive_data["credits"]["cast"] || [])
      crew_count = length(comprehensive_data["credits"]["crew"] || [])
      IO.puts("  ✅ credits: #{cast_count} cast, #{crew_count} crew")
    else
      IO.puts("  ❌ credits: not present")
    end
    
    if comprehensive_data["images"] do
      images = comprehensive_data["images"]
      IO.puts("  ✅ images:")
      IO.puts("     - posters: #{length(images["posters"] || [])}")
      IO.puts("     - backdrops: #{length(images["backdrops"] || [])}")
      IO.puts("     - logos: #{length(images["logos"] || [])}")
    else
      IO.puts("  ❌ images: not present")
    end
    
    if comprehensive_data["keywords"] do
      keywords = comprehensive_data["keywords"]["keywords"] || []
      IO.puts("  ✅ keywords: #{length(keywords)} keywords")
      if length(keywords) > 0 do
        sample_keywords = keywords |> Enum.take(5) |> Enum.map(& &1["name"]) |> Enum.join(", ")
        IO.puts("     Sample: #{sample_keywords}")
      end
    else
      IO.puts("  ❌ keywords: not present")
    end
    
    if comprehensive_data["external_ids"] do
      ext_ids = comprehensive_data["external_ids"]
      IO.puts("  ✅ external_ids: #{inspect(Map.keys(ext_ids))}")
    else
      IO.puts("  ❌ external_ids: not present")
    end
    
    if comprehensive_data["release_dates"] do
      results = comprehensive_data["release_dates"]["results"] || []
      IO.puts("  ✅ release_dates: #{length(results)} countries")
      if length(results) > 0 do
        sample = hd(results)
        IO.puts("     Sample: #{sample["iso_3166_1"]} - #{length(sample["release_dates"] || [])} releases")
      end
    else
      IO.puts("  ❌ release_dates: not present")
    end
    
    if comprehensive_data["videos"] do
      videos = comprehensive_data["videos"]["results"] || []
      IO.puts("  ✅ videos: #{length(videos)} videos")
      if length(videos) > 0 do
        types = videos |> Enum.map(& &1["type"]) |> Enum.frequencies()
        IO.puts("     Types: #{inspect(types)}")
      end
    else
      IO.puts("  ❌ videos: not present")
    end
    
    if comprehensive_data["recommendations"] do
      recs = comprehensive_data["recommendations"]["results"] || []
      IO.puts("  ✅ recommendations: #{length(recs)} movies")
    else
      IO.puts("  ❌ recommendations: not present")
    end
    
    if comprehensive_data["similar"] do
      similar = comprehensive_data["similar"]["results"] || []
      IO.puts("  ✅ similar: #{length(similar)} movies")
    else
      IO.puts("  ❌ similar: not present")
    end
    
    if comprehensive_data["alternative_titles"] do
      titles = comprehensive_data["alternative_titles"]["titles"] || []
      IO.puts("  ✅ alternative_titles: #{length(titles)} titles")
    else
      IO.puts("  ❌ alternative_titles: not present")
    end
    
    if comprehensive_data["translations"] do
      trans = comprehensive_data["translations"]["translations"] || []
      IO.puts("  ✅ translations: #{length(trans)} languages")
    else
      IO.puts("  ❌ translations: not present")
    end
    
    # Check for any fields we might be missing
    known_fields = ~w(adult backdrop_path belongs_to_collection budget credits external_ids
                      genres homepage id images imdb_id keywords original_language original_title
                      overview popularity poster_path production_companies production_countries
                      recommendations release_date release_dates revenue runtime similar
                      spoken_languages status tagline title translations video videos
                      vote_average vote_count alternative_titles)
    
    unknown_fields = Map.keys(comprehensive_data) -- known_fields
    if length(unknown_fields) > 0 do
      IO.puts("\n⚠️  Unknown fields found: #{inspect(unknown_fields)}")
    end
    
    # Save raw data for inspection
    File.write!("tmdb_sample_response.json", Jason.encode!(comprehensive_data, pretty: true))
    IO.puts("\n💾 Full response saved to tmdb_sample_response.json")
    
  {:error, reason} ->
    IO.puts("❌ Failed to fetch comprehensive data: #{inspect(reason)}")
end

IO.puts("\n\n3️⃣ Additional TMDB Endpoints Available:")
IO.puts("-" <> String.duplicate("-", 40))

IO.puts("""
According to TMDB API docs, these endpoints are available but not in append_to_response:

Movie-specific:
- /movie/{id}/watch/providers - Streaming availability by country
- /movie/{id}/lists - Lists containing this movie
- /movie/{id}/reviews - User reviews
- /movie/{id}/changes - Change history

General endpoints:
- /configuration - Image sizes, change keys, etc.
- /genre/movie/list - All available genres
- /certification/movie/list - All certifications by country
- /watch/providers/movie - All streaming providers

Person-specific (when fetched separately):
- /person/{id}/movie_credits - Complete filmography
- /person/{id}/tv_credits - TV credits
- /person/{id}/combined_credits - Both movie & TV
- /person/{id}/images - Profile images
- /person/{id}/tagged_images - Images they're tagged in
- /person/{id}/changes - Change history
""")
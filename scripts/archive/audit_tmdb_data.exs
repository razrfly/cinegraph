# Audit what TMDB data we're missing
alias Cinegraph.Services.TMDb

IO.puts("🎬 Auditing TMDB API vs our data collection...\n")

# Test with The Godfather
movie_id = 238

IO.puts("Fetching standard comprehensive data...")
{:ok, standard} = TMDb.get_movie_comprehensive(movie_id)

IO.puts("\nFetching ULTRA comprehensive data...")
{:ok, ultra} = TMDb.get_movie_ultra_comprehensive(movie_id)

IO.puts("\n📊 Data available from TMDB:")
IO.puts("=" <> String.duplicate("=", 60))

# Check what's in each response
standard_keys = Map.keys(standard) |> Enum.sort()
ultra_keys = Map.keys(ultra) |> Enum.sort()

IO.puts("\nStandard comprehensive keys (#{length(standard_keys)}):")
Enum.each(standard_keys, fn key ->
  data = standard[key]
  case data do
    %{} = map when map != %{} -> 
      IO.puts("  ✅ #{key}: #{map_size(map)} fields")
    [_ | _] = list -> 
      IO.puts("  ✅ #{key}: #{length(list)} items")
    nil -> 
      IO.puts("  ❌ #{key}: nil")
    _ -> 
      IO.puts("  ✅ #{key}: #{inspect(data) |> String.slice(0, 50)}")
  end
end)

IO.puts("\n🆕 Additional in ULTRA comprehensive:")
extra_keys = ultra_keys -- standard_keys
Enum.each(extra_keys, fn key ->
  data = ultra[key]
  case data do
    %{"results" => results} when is_list(results) ->
      IO.puts("  🔥 #{key}: #{length(results)} results")
    %{"results" => results} when is_map(results) ->
      IO.puts("  🔥 #{key}: #{map_size(results)} regions")
    _ ->
      IO.puts("  🔥 #{key}: #{inspect(data) |> String.slice(0, 50)}")
  end
end)

# Check specific data we care about
IO.puts("\n🎯 Specific data check:")

# Lists
if ultra["lists"] do
  IO.puts("\nTMDB Lists containing this movie:")
  case ultra["lists"]["results"] do
    [_ | _] = lists ->
      IO.puts("  Found #{length(lists)} lists")
      lists |> Enum.take(3) |> Enum.each(fn list ->
        IO.puts("  - #{list["name"]} by #{list["created_by"]["username"] || "unknown"}")
      end)
    _ ->
      IO.puts("  No lists found")
  end
end

# Watch providers
if ultra["watch/providers"] || ultra["watch_providers"] do
  providers = ultra["watch/providers"] || ultra["watch_providers"]
  IO.puts("\nWatch providers:")
  case providers["results"] do
    results when is_map(results) ->
      IO.puts("  Available in #{map_size(results)} regions")
      results |> Map.take(["US", "GB", "FR"]) |> Enum.each(fn {region, data} ->
        types = []
        types = if data["flatrate"], do: ["streaming" | types], else: types
        types = if data["rent"], do: ["rent" | types], else: types
        types = if data["buy"], do: ["buy" | types], else: types
        IO.puts("  #{region}: #{Enum.join(types, ", ")}")
      end)
    _ ->
      IO.puts("  No provider data")
  end
end

# Reviews
if ultra["reviews"] do
  IO.puts("\nUser reviews:")
  case ultra["reviews"]["results"] do
    [_ | _] = reviews ->
      IO.puts("  Found #{length(reviews)} reviews")
    _ ->
      IO.puts("  No reviews")
  end
end

IO.puts("\n❌ PROBLEMS IDENTIFIED:")
IO.puts("1. We're using get_movie_comprehensive, NOT get_movie_ultra_comprehensive")
IO.puts("2. We're missing: watch providers, reviews, TMDB user lists")
IO.puts("3. We're not processing alternative_titles or translations (even though we fetch them)")

IO.puts("\n📋 What we're currently processing:")
IO.puts("  ✅ credits (cast/crew)")
IO.puts("  ✅ keywords")
IO.puts("  ✅ videos")
IO.puts("  ✅ release_dates")
IO.puts("  ✅ production_companies")
IO.puts("  ✅ recommendations")
IO.puts("  ✅ similar")
IO.puts("  ✅ external_ids")
IO.puts("  ✅ images")
IO.puts("  ❌ watch/providers")
IO.puts("  ❌ reviews")
IO.puts("  ❌ lists")
IO.puts("  ❌ alternative_titles")
IO.puts("  ❌ translations")

IO.puts("\n🔧 Also missing from TMDB Extended module:")
extended_endpoints = [
  "get_movie_lists (containing lists)",
  "get_movie_reviews",
  "get_trending_movies",
  "get_now_playing_movies",
  "get_upcoming_movies",
  "get_movie_certifications"
]

IO.puts("\nOther TMDB endpoints we have but aren't using:")
Enum.each(extended_endpoints, &IO.puts("  - #{&1}"))
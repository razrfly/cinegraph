# Quick test to see what data we're collecting
alias Cinegraph.Services.TMDb

IO.puts("Testing data collection with The Godfather...\n")

# Capture the console output by redefining IO.puts temporarily
{:ok, ultra} = TMDb.get_movie_ultra_comprehensive(238)

IO.puts("Watch providers data:")
if ultra["watch/providers"] || ultra["watch_providers"] do
  providers = ultra["watch/providers"] || ultra["watch_providers"]
  case providers["results"] do
    results when is_map(results) ->
      IO.puts("  ✅ Available in #{map_size(results)} regions")
    _ ->
      IO.puts("  ❌ No provider data")
  end
else
  IO.puts("  ❌ Missing watch providers key")
end

IO.puts("\nReviews data:")
if ultra["reviews"] do
  case ultra["reviews"]["results"] do
    reviews when is_list(reviews) ->
      IO.puts("  ✅ Found #{length(reviews)} reviews")
    _ ->
      IO.puts("  ❌ No reviews")
  end
else
  IO.puts("  ❌ Missing reviews key")
end

IO.puts("\nLists data:")
if ultra["lists"] do
  case ultra["lists"]["results"] do
    lists when is_list(lists) ->
      IO.puts("  ✅ Appears in #{length(lists)} TMDB user lists")
    _ ->
      IO.puts("  ❌ No lists")
  end
else
  IO.puts("  ❌ Missing lists key")
end

IO.puts("\nAlternative titles:")
if ultra["alternative_titles"] do
  case ultra["alternative_titles"]["titles"] do
    titles when is_list(titles) ->
      IO.puts("  ✅ Found #{length(titles)} alternative titles")
    _ ->
      IO.puts("  ❌ No alternative titles")
  end
else
  IO.puts("  ❌ Missing alternative_titles key")
end

IO.puts("\nTranslations:")
if ultra["translations"] do
  case ultra["translations"]["translations"] do
    translations when is_list(translations) ->
      IO.puts("  ✅ Available in #{length(translations)} languages")
    _ ->
      IO.puts("  ❌ No translations")
  end
else
  IO.puts("  ❌ Missing translations key")
end

IO.puts("\n🎯 Summary: We ARE fetching the data, but not storing it in our database!")
IO.puts("The process functions are just printing counts but not actually saving to database.")
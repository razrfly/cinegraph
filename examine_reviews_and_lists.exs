# Let's examine what's actually in reviews and lists data
alias Cinegraph.Services.TMDb

IO.puts("🎬 Examining TMDB Reviews and Lists data...\n")

# Get The Godfather data
{:ok, movie} = TMDb.get_movie_ultra_comprehensive(238)

IO.puts(String.duplicate("=", 80))
IO.puts("REVIEWS DATA")
IO.puts(String.duplicate("=", 80))

if movie["reviews"] && movie["reviews"]["results"] do
  reviews = movie["reviews"]["results"]
  IO.puts("Total reviews: #{length(reviews)}\n")
  
  # Show first 3 reviews
  reviews |> Enum.take(3) |> Enum.with_index(1) |> Enum.each(fn {review, idx} ->
    IO.puts("Review ##{idx}:")
    IO.puts("  Author: #{review["author"]}")
    IO.puts("  Author Details: #{inspect(review["author_details"])}")
    IO.puts("  Created: #{review["created_at"]}")
    IO.puts("  Updated: #{review["updated_at"]}")
    IO.puts("  Content preview: #{String.slice(review["content"] || "", 0, 200)}...")
    IO.puts("  URL: #{review["url"]}")
    IO.puts("")
  end)
else
  IO.puts("No reviews data")
end

IO.puts("\n" <> String.duplicate("=", 80))
IO.puts("LISTS DATA")
IO.puts(String.duplicate("=", 80))

if movie["lists"] && movie["lists"]["results"] do
  lists = movie["lists"]["results"]
  IO.puts("Movie appears in #{length(lists)} lists\n")
  
  # Show first 5 lists
  lists |> Enum.take(5) |> Enum.with_index(1) |> Enum.each(fn {list, idx} ->
    IO.puts("List ##{idx}:")
    IO.puts("  Name: #{list["name"]}")
    IO.puts("  Description: #{list["description"] || "No description"}")
    IO.puts("  Created by: #{list["created_by"]["username"] || "Unknown"}")
    IO.puts("  Item count: #{list["item_count"]}")
    IO.puts("  Public: #{list["public"]}")
    IO.puts("  Type: #{list["list_type"]}")
    IO.puts("  ISO 639-1: #{list["iso_639_1"] || "N/A"}")
    IO.puts("")
  end)
  
  # Check if any lists might be from authoritative sources
  IO.puts("\n🔍 Checking for potentially authoritative lists:")
  lists |> Enum.each(fn list ->
    name = String.downcase(list["name"] || "")
    if String.contains?(name, ["award", "oscar", "academy", "cannes", "criterion", "afi", "best", "greatest", "top"]) do
      IO.puts("  📌 '#{list["name"]}' by #{list["created_by"]["username"] || "unknown"} (#{list["item_count"]} items)")
    end
  end)
else
  IO.puts("No lists data")
end

IO.puts("\n🎯 ANALYSIS:")
IO.puts("- Reviews: These are individual user reviews from TMDB users (not professional critics)")
IO.puts("- Lists: These are user-created lists, but some might track awards or 'best of' collections")
IO.puts("- Neither provides authoritative cultural data, but list names might indicate cultural relevance")
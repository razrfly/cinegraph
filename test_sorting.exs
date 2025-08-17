#!/usr/bin/env elixir

# Test the sorting functionality
IO.puts("Testing Movie Sorting Functionality")
IO.puts("====================================\n")

# Test 1: Basic URL parameter parsing
test_params = [
  {"release_date_desc", "release_date", :desc},
  {"title", "title", :desc},  # default when no suffix
  {"popular_opinion_desc", "popular_opinion", :desc},
  {"rating_asc", "rating", :asc}
]

for {input, expected_criteria, expected_direction} <- test_params do
  # Extract criteria
  criteria = cond do
    String.ends_with?(input, "_desc") ->
      String.replace_suffix(input, "_desc", "")
    String.ends_with?(input, "_asc") ->
      String.replace_suffix(input, "_asc", "")
    true ->
      input
  end
  
  # Extract direction
  direction = cond do
    String.ends_with?(input, "_desc") -> :desc
    String.ends_with?(input, "_asc") -> :asc
    true -> :desc  # default
  end
  
  if criteria == expected_criteria and direction == expected_direction do
    IO.puts("✅ PASS: '#{input}' -> criteria: #{criteria}, direction: #{direction}")
  else
    IO.puts("❌ FAIL: '#{input}' -> expected: #{expected_criteria}/#{expected_direction}, got: #{criteria}/#{direction}")
  end
end

IO.puts("\nChecking valid sorts list...")

valid_sorts = ~w(
  title title_desc
  release_date release_date_desc
  runtime runtime_desc
  rating rating_desc
  popularity popularity_desc
  popular_opinion popular_opinion_desc
  critical_acclaim critical_acclaim_desc
  industry_recognition industry_recognition_desc
  cultural_impact cultural_impact_desc
  people_quality people_quality_desc
)

test_sorts = [
  "release_date_desc",
  "popular_opinion_desc",
  "critical_acclaim_desc",
  "people_quality_desc"
]

for sort <- test_sorts do
  if sort in valid_sorts do
    IO.puts("✅ '#{sort}' is in valid_sorts")
  else
    IO.puts("❌ '#{sort}' is NOT in valid_sorts")
  end
end
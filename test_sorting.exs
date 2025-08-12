#!/usr/bin/env elixir

# Simple test script to verify sorting functionality
# Run with: mix run test_sorting.exs

import Ecto.Query
alias Cinegraph.Movies
alias Cinegraph.Repo

IO.puts("\n=== Testing Movie Sorting Functionality ===\n")

# Test different sort options
sort_options = [
  {"release_date_desc", "Release Date (Newest)"},
  {"release_date", "Release Date (Oldest)"},
  {"title", "Title (A-Z)"},
  {"title_desc", "Title (Z-A)"},
  {"rating", "Rating (Highest)"},
  {"popularity", "Popularity"}
]

Enum.each(sort_options, fn {sort_value, description} ->
  IO.puts("Testing sort: #{description} (#{sort_value})")
  
  params = %{
    "sort" => sort_value,
    "page" => "1",
    "per_page" => "5"
  }
  
  movies = Movies.list_movies(params)
  
  if length(movies) > 0 do
    IO.puts("  First 3 movies:")
    movies
    |> Enum.take(3)
    |> Enum.each(fn movie ->
      case sort_value do
        "release_date" <> _ ->
          IO.puts("    - #{movie.title} (Released: #{movie.release_date || "N/A"})")
        "title" <> _ ->
          IO.puts("    - #{movie.title}")
        "rating" ->
          # Try to get rating from external_metrics
          rating = case Cinegraph.Repo.one(
            from em in "external_metrics",
            where: em.movie_id == ^movie.id and 
                   em.source == "tmdb" and 
                   em.metric_type == "rating_average",
            order_by: [desc: em.fetched_at],
            limit: 1,
            select: em.value
          ) do
            nil -> "N/A"
            value -> Float.round(value, 1)
          end
          IO.puts("    - #{movie.title} (Rating: #{rating})")
        "popularity" ->
          # Try to get popularity from external_metrics
          popularity = case Cinegraph.Repo.one(
            from em in "external_metrics",
            where: em.movie_id == ^movie.id and 
                   em.source == "tmdb" and 
                   em.metric_type == "popularity_score",
            order_by: [desc: em.fetched_at],
            limit: 1,
            select: em.value
          ) do
            nil -> "N/A"
            value -> Float.round(value, 1)
          end
          IO.puts("    - #{movie.title} (Popularity: #{popularity})")
        _ ->
          IO.puts("    - #{movie.title}")
      end
    end)
  else
    IO.puts("  No movies found")
  end
  
  IO.puts("")
end)

IO.puts("=== Sorting Test Complete ===")
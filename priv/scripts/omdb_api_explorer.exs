#!/usr/bin/env elixir
# OMDb API Explorer — confirms current API response structure
#
# Usage: mix run priv/scripts/omdb_api_explorer.exs
#
# Makes 3 calls for tt0111161 (The Shawshank Redemption) and compares:
#   Call A — standard (no extras)
#   Call B — with tomatoes: true (deprecated check)
#   Call C — with plot=full
#
# Also queries stored DB data for tomatoURL coverage.

alias Cinegraph.Services.OMDb.Client
alias Cinegraph.Repo
alias Cinegraph.Movies.Movie
import Ecto.Query

test_imdb_id = "tt0111161"

defmodule OMDbExplorer do
  # Fields currently extracted by from_omdb/2
  @extracted_fields ~w(
    imdbRating imdbVotes Metascore BoxOffice Awards Ratings tomatoURL
    Rated
  )

  def separator(label) do
    IO.puts("\n" <> String.duplicate("=", 60))
    IO.puts("  #{label}")
    IO.puts(String.duplicate("=", 60))
  end

  def print_fields(data, label) do
    IO.puts("\n--- #{label} ---")

    data
    |> Enum.sort_by(fn {k, _} -> k end)
    |> Enum.each(fn {key, value} ->
      extracted = if key in @extracted_fields, do: " [EXTRACTED]", else: " [ignored]"
      value_str = inspect(value, limit: 80, printable_limit: 80)
      IO.puts("  #{String.pad_trailing(key, 22)} #{value_str}#{extracted}")
    end)
  end

  def diff_calls(a, b, label_a, label_b) do
    IO.puts("\n--- Differences: #{label_a} vs #{label_b} ---")

    keys = MapSet.union(MapSet.new(Map.keys(a)), MapSet.new(Map.keys(b)))

    diffs =
      Enum.filter(keys, fn k ->
        Map.get(a, k) != Map.get(b, k)
      end)

    if diffs == [] do
      IO.puts("  (no differences)")
    else
      Enum.each(diffs, fn k ->
        IO.puts("  #{k}:")
        IO.puts("    #{label_a}: #{inspect(Map.get(a, k))}")
        IO.puts("    #{label_b}: #{inspect(Map.get(b, k))}")
      end)
    end
  end

  def tomato_field_analysis(data) do
    IO.puts("\n--- tomatoXxx field analysis ---")

    tomato_keys = Map.keys(data) |> Enum.filter(&String.starts_with?(&1, "tomato"))

    if tomato_keys == [] do
      IO.puts("  No tomatoXxx fields returned.")
    else
      Enum.each(tomato_keys, fn k ->
        v = data[k]
        status = if v in [nil, "N/A"], do: "N/A (dead)", else: "POPULATED: #{inspect(v)}"
        IO.puts("  #{String.pad_trailing(k, 24)} #{status}")
      end)
    end
  end
end

# ---- Live API Calls ----

OMDbExplorer.separator("Call A — Standard (no tomatoes param)")

call_a =
  case Client.get_movie_by_imdb_id(test_imdb_id) do
    {:ok, data} ->
      IO.puts("SUCCESS — #{map_size(data)} fields returned")
      OMDbExplorer.print_fields(data, "All fields")
      OMDbExplorer.tomato_field_analysis(data)
      data

    {:error, reason} ->
      IO.puts("ERROR: #{inspect(reason)}")
      %{}
  end

OMDbExplorer.separator("Call B — With tomatoes: true")

call_b =
  case HTTPoison.get(
         "https://www.omdbapi.com/?i=#{test_imdb_id}&tomatoes=true&plot=short&r=json&apikey=#{Application.get_env(:cinegraph, Cinegraph.Services.OMDb.Client)[:api_key]}",
         [],
         timeout: 30_000,
         recv_timeout: 30_000
       ) do
    {:ok, %{status_code: 200, body: body}} ->
      case Jason.decode(body) do
        {:ok, data} ->
          IO.puts("SUCCESS — #{map_size(data)} fields returned")
          OMDbExplorer.print_fields(data, "All fields")
          OMDbExplorer.tomato_field_analysis(data)
          data

        {:error, e} ->
          IO.puts("JSON decode error: #{inspect(e)}")
          %{}
      end

    {:ok, %{status_code: code}} ->
      IO.puts("HTTP #{code}")
      %{}

    {:error, e} ->
      IO.puts("Request error: #{inspect(e)}")
      %{}
  end

OMDbExplorer.separator("Call C — With plot=full")

call_c =
  case HTTPoison.get(
         "https://www.omdbapi.com/?i=#{test_imdb_id}&plot=full&r=json&apikey=#{Application.get_env(:cinegraph, Cinegraph.Services.OMDb.Client)[:api_key]}",
         [],
         timeout: 30_000,
         recv_timeout: 30_000
       ) do
    {:ok, %{status_code: 200, body: body}} ->
      case Jason.decode(body) do
        {:ok, data} ->
          IO.puts("SUCCESS — #{map_size(data)} fields returned")
          IO.puts("  Plot (short): #{inspect(call_a["Plot"])}")
          IO.puts("  Plot (full):  #{inspect(data["Plot"])}")
          data

        {:error, e} ->
          IO.puts("JSON decode error: #{inspect(e)}")
          %{}
      end

    {:ok, %{status_code: code}} ->
      IO.puts("HTTP #{code}")
      %{}

    {:error, e} ->
      IO.puts("Request error: #{inspect(e)}")
      %{}
  end

# ---- Diffs ----

OMDbExplorer.separator("Diffs")
OMDbExplorer.diff_calls(call_a, call_b, "Call A", "Call B (tomatoes:true)")

# ---- DB Analysis ----

OMDbExplorer.separator("DB Analysis — tomatoURL coverage in stored omdb_data")

total =
  Repo.one(from m in Movie, where: not is_nil(m.omdb_data), select: count(m.id))

with_tomato_url =
  Repo.one(
    from m in Movie,
      where: not is_nil(m.omdb_data),
      where: fragment("omdb_data->>'tomatoURL' IS NOT NULL"),
      where: fragment("omdb_data->>'tomatoURL' != 'N/A'"),
      select: count(m.id)
  )

na_tomato_url =
  Repo.one(
    from m in Movie,
      where: not is_nil(m.omdb_data),
      where: fragment("omdb_data->>'tomatoURL' = 'N/A'"),
      select: count(m.id)
  )

null_tomato_url = total - with_tomato_url - na_tomato_url

IO.puts("\n  Total movies with omdb_data: #{total}")
IO.puts("  tomatoURL populated (non-N/A): #{with_tomato_url}")
IO.puts("  tomatoURL = N/A:               #{na_tomato_url}")
IO.puts("  tomatoURL missing/null:         #{null_tomato_url}")

if total > 0 do
  pct = Float.round(with_tomato_url / total * 100, 1)
  IO.puts("  Coverage: #{pct}% have a valid tomatoURL")
end

# ---- Rated field coverage ----

OMDbExplorer.separator("DB Analysis — Rated (content rating) coverage")

rated_counts =
  Repo.all(
    from m in Movie,
      where: not is_nil(m.omdb_data),
      where: fragment("omdb_data->>'Rated' IS NOT NULL"),
      group_by: fragment("omdb_data->>'Rated'"),
      select: {fragment("omdb_data->>'Rated'"), count(m.id)},
      order_by: [desc: count(m.id)]
  )

if rated_counts == [] do
  IO.puts("\n  No Rated field found in stored data.")
else
  IO.puts("\n  Value distribution:")

  Enum.each(rated_counts, fn {rated, count} ->
    IO.puts("    #{String.pad_trailing(rated || "NULL", 12)} #{count}")
  end)
end

IO.puts("\n#{String.duplicate("=", 60)}")
IO.puts("Explorer complete.")
IO.puts(String.duplicate("=", 60) <> "\n")

defmodule CinegraphWeb.MovieLive.IndexV2Components.SortLabels do
  @moduledoc """
  Display labels, tooltips, and grouping for V2 movie sort controls.
  """

  def short(%{value: "release_date"}), do: "📅 Most recent"
  def short(%{value: "score"}), do: "⭐ Highest rated"
  def short(%{value: "popularity"}), do: "🔥 Trending"
  def short(%{label: label}), do: label

  def display(%{value: "release_date"}), do: "📅 Most recent"
  def display(%{value: "score"}), do: "⭐ Highest rated"
  def display(%{value: "popularity"}), do: "🔥 Trending"
  def display(%{value: "mob"}), do: "👥 Audience"
  def display(%{value: "critics"}), do: "🎭 Critics"
  def display(%{value: "festival_recognition"}), do: "🏆 Awards"
  def display(%{value: "time_machine"}), do: "⏳ All-time canon"
  def display(%{value: "auteurs"}), do: "🎬 Director picks"
  def display(%{label: label}), do: label

  def tooltip(%{value: "release_date"}), do: "Newest releases first"
  def tooltip(%{value: "score"}), do: "Top of the Cinegraph composite score"
  def tooltip(%{value: "popularity"}), do: "What's hot right now (TMDb popularity)"
  def tooltip(%{value: "rating"}), do: "Sorted by raw user rating"
  def tooltip(%{value: "mob"}), do: "What audiences love (IMDb + TMDb + Rotten Tomatoes)"
  def tooltip(%{value: "critics"}), do: "What critics rate highly (Metacritic + Rotten Tomatoes)"
  def tooltip(%{value: "festival_recognition"}), do: "Festival wins and major-award presence"

  def tooltip(%{value: "time_machine"}),
    do: "Films that survive — Criterion, 1001 Movies, Sight & Sound"

  def tooltip(%{value: "auteurs"}), do: "Great directors, great casts"
  def tooltip(%{value: "title"}), do: "Alphabetical by title"
  def tooltip(%{value: "runtime"}), do: "By length (longest first)"
  def tooltip(%{label: label}), do: label

  def overflow_summary(criteria, direction, primary_opts, overflow_opts) do
    primary_values = Enum.map(primary_opts, & &1.value)

    if criteria in primary_values do
      "More sorts ▾"
    else
      case Enum.find(overflow_opts, &(&1.value == criteria)) do
        nil -> "More sorts ▾"
        opt -> "#{display(opt)} #{direction_arrow(direction)} ▾"
      end
    end
  end

  def grouped_overflow_options(overflow_opts) do
    timeline_keys = ~w(title runtime)
    quality_keys = ~w(rating critics mob festival_recognition)
    lens_keys = ~w(time_machine auteurs)

    by_value = Map.new(overflow_opts, fn opt -> {opt.value, opt} end)
    presets = Enum.filter(overflow_opts, fn opt -> Map.get(opt, :group) == "Scored Presets" end)

    [
      {"Timeline", Enum.map(timeline_keys, &Map.get(by_value, &1)) |> Enum.reject(&is_nil/1)},
      {"Quality", Enum.map(quality_keys, &Map.get(by_value, &1)) |> Enum.reject(&is_nil/1)},
      {"Cinegraph lenses", Enum.map(lens_keys, &Map.get(by_value, &1)) |> Enum.reject(&is_nil/1)},
      {"Scored presets", presets}
    ]
    |> Enum.reject(fn {_, opts} -> opts == [] end)
  end

  def direction_arrow(:asc), do: "↑"
  def direction_arrow(_), do: "↓"
end

defmodule CinegraphWeb.MovieLive.ShowV2.ListAppearance do
  @moduledoc false

  def href(%{slug: slug}) when is_binary(slug) and slug != "",
    do: "/lists/#{slug}"

  def href(_), do: nil

  def title(list),
    do: non_blank(list[:short_name]) || non_blank(list[:list_name]) || "Untitled list"

  def eyebrow(list) do
    label =
      [list[:category], list[:list_year]]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.map(&to_string/1)
      |> Enum.map(&String.upcase/1)
      |> Enum.join(" · ")

    if label == "", do: nil, else: label
  end

  def rank(%{rank: rank}) when is_integer(rank), do: "##{rank}"
  def rank(_), do: "Included"

  def image(list), do: list[:cover_image_url] || list[:hero_image_url]

  def initials(list) do
    title = title(list)

    initials =
      title
      |> String.split(~r/\s+/, trim: true)
      |> Enum.reject(&(&1 in ["The", "A", "An", "of", "and", "&", "|"]))
      |> Enum.take(3)
      |> Enum.map(&String.first/1)
      |> Enum.join("")
      |> String.upcase()

    if initials == "" do
      title
      |> String.split(~r/\s+/, trim: true)
      |> Enum.take(3)
      |> Enum.map(&String.first/1)
      |> Enum.join("")
      |> String.upcase()
    else
      initials
    end
  end

  def visual_class(list) do
    case list[:category] do
      "critics" -> "from-amber-100 to-mist-200"
      "registry" -> "from-sky-100 to-mist-200"
      "curated" -> "from-emerald-100 to-mist-200"
      "personal" -> "from-rose-100 to-mist-200"
      _ -> "from-mist-100 to-mist-300"
    end
  end

  defp non_blank(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: value
  end

  defp non_blank(_), do: nil
end

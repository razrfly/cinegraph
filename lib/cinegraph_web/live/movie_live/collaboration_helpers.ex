defmodule CinegraphWeb.MovieLive.CollaborationHelpers do
  @moduledoc """
  URL helpers for movie collaboration affordances.
  """

  @doc """
  Builds a movie-index URL that searches for films containing both people in a
  collaboration.
  """
  def collaboration_search_href(collaboration) do
    people =
      [collaboration[:person_a], collaboration[:person_b]]
      |> Enum.map(&person_filter_value/1)
      |> Enum.reject(&(&1 in [nil, ""]))

    case people do
      [_, _] ->
        encoded_people =
          people
          |> Enum.map(&URI.encode_www_form/1)
          |> Enum.join(",")

        "/movies?people=#{encoded_people}&people_match=all"

      _ ->
        nil
    end
  end

  defp person_filter_value(%{slug: slug}) when is_binary(slug) and slug != "", do: slug
  defp person_filter_value(%{id: id}) when not is_nil(id), do: to_string(id)
  defp person_filter_value(_person), do: nil
end

defmodule CinegraphWeb.Helpers.UrlHelpers do
  @moduledoc """
  Shared URL helpers for Cinegraph web views and components.
  """

  def movie_href(slug, _id) when is_binary(slug) and slug != "", do: "/movies-v2/#{slug}"
  def movie_href(_slug, id), do: "/movies/#{id}"
end

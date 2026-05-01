defmodule CinegraphWeb.Helpers.UrlHelpers do
  @moduledoc """
  Shared URL helpers for Cinegraph web views and components.
  """

  # /movies/:slug is now the V2 primary (issue #792). /movies-v2/:slug
  # remains as an alias for any open tabs, but new links use the clean URL.
  def movie_href(slug, _id) when is_binary(slug) and slug != "", do: "/movies/#{slug}"
  def movie_href(_slug, id), do: "/movies/#{id}"
end

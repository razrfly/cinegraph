defmodule CinegraphWeb.Helpers.WombieLinks do
  @moduledoc """
  Builds Wombie.com deep-links with UTM attribution for cross-site referral tracking.

  Uses the slug-based URL format (`/movies/{slug}-{tmdb_id}`) until #875 Phase B
  ships on Wombie and adds a stable `/movies/tmdb/:id` resolver.
  """

  @doc """
  Returns a Wombie showtimes URL for the given movie and campaign surface.

  ## Campaigns
    - `"now_playing"` — now-playing feed card
    - `"movie_show"` — movie detail page band
    - `"graphql"` — API consumers
  """
  def showtimes_url(movie, campaign \\ "now_playing") do
    base =
      :cinegraph
      |> Application.get_env(:wombie_base_url, "https://wombie.com")
      |> String.trim_trailing("/")

    "#{base}/movies/#{movie.slug}-#{movie.tmdb_id}" <>
      "?utm_source=cinegraph&utm_medium=referral&utm_campaign=#{campaign}"
  end
end

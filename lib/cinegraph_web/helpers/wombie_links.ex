defmodule CinegraphWeb.Helpers.WombieLinks do
  @moduledoc """
  Builds Wombie.com deep-links with UTM attribution for cross-site referral tracking.

  Uses the slug-based URL format (`/movies/{slug}-{tmdb_id}`) until #875 Phase B
  ships on Wombie and adds a stable `/movies/tmdb/:id` resolver.
  """

  @doc """
  Returns a Wombie showtimes URL for the given movie and campaign surface.
  Returns `nil` when the movie has no slug.

  ## Campaigns
    - `"now_playing"` — now-playing feed card
    - `"movie_show"` — movie detail page band
    - `"graphql"` — API consumers
  """
  def showtimes_url(movie, campaign \\ "now_playing") do
    if movie.slug && movie.slug != "" do
      base = wombie_base()

      "#{base}/movies/#{movie.slug}-#{movie.tmdb_id}" <>
        "?utm_source=cinegraph&utm_medium=referral&utm_campaign=#{campaign}"
    end
  end

  @doc "Returns the Wombie homepage URL with UTM attribution for a given campaign surface."
  def homepage_url(campaign) do
    "#{wombie_base()}?utm_source=cinegraph&utm_medium=referral&utm_campaign=#{campaign}"
  end

  defp wombie_base do
    :cinegraph
    |> Application.get_env(:wombie_base_url, "https://wombie.com")
    |> String.trim_trailing("/")
  end
end

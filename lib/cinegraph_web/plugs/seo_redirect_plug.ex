defmodule CinegraphWeb.Plugs.SEORedirectPlug do
  @moduledoc """
  Plug to handle SEO-friendly 301 redirects for movie and person pages.

  When a numeric ID is used in the URL, this plug redirects to the canonical slug URL
  with a 301 (Moved Permanently) status code. This ensures search engines properly
  index the canonical URLs and transfer link equity.

  ## Examples

      /movies/550 -> 301 -> /movies/fight-club-1999
      /people/287 -> 301 -> /people/brad-pitt

  Note: This plug only handles the main show routes. TMDb ID and IMDb ID routes
  are handled by the LiveView since they may need to fetch/create movies.
  """

  import Plug.Conn
  alias Cinegraph.Repo

  def init(opts), do: opts

  def call(%Plug.Conn{path_info: ["movies", id_or_slug]} = conn, _opts) do
    if numeric_id?(id_or_slug) do
      redirect_movie_to_slug(conn, id_or_slug)
    else
      conn
    end
  end

  def call(%Plug.Conn{path_info: ["people", id_or_slug]} = conn, _opts) do
    if numeric_id?(id_or_slug) do
      redirect_person_to_slug(conn, id_or_slug)
    else
      conn
    end
  end

  def call(conn, _opts), do: conn

  defp numeric_id?(str) do
    case Integer.parse(str) do
      {_num, ""} -> true
      _ -> false
    end
  end

  defp redirect_movie_to_slug(conn, id) do
    import Ecto.Query, only: [from: 2]
    alias Cinegraph.Movies.Movie

    case Repo.one(from m in Movie, where: m.id == ^String.to_integer(id), select: m.slug) do
      slug when is_binary(slug) and slug != "" ->
        conn
        |> put_resp_header("location", "/movies/#{slug}")
        |> put_resp_header("cache-control", "public, max-age=86400")
        |> send_resp(301, "")
        |> halt()

      _ ->
        # No movie or no slug, let LiveView handle the error
        conn
    end
  end

  defp redirect_person_to_slug(conn, id) do
    import Ecto.Query, only: [from: 2]
    alias Cinegraph.Movies.Person

    case Repo.one(from p in Person, where: p.id == ^String.to_integer(id), select: p.slug) do
      slug when is_binary(slug) and slug != "" ->
        conn
        |> put_resp_header("location", "/people/#{slug}")
        |> put_resp_header("cache-control", "public, max-age=86400")
        |> send_resp(301, "")
        |> halt()

      _ ->
        # No person or no slug, let LiveView handle the error
        conn
    end
  end
end

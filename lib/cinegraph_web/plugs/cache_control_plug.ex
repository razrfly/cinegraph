defmodule CinegraphWeb.Plugs.CacheControlPlug do
  @moduledoc """
  Smart cache control headers for different route types.

  ## Caching Strategy

  LiveView HTML embeds per-session CSRF tokens used by the LiveView socket.
  Browsers or CDNs must not reuse cached HTML, because stale tokens can leave
  clients in a reconnect/reload loop.

  ### Cache Tiers

  ### Non-Cacheable HTML Pages
  - LiveView detail pages (`/movies/:slug`, `/people/:slug`, lists, awards)
  - Search and discovery pages
  - Admin dashboards
  - All other dynamic HTML pages

  LiveView pages must not be cached by CDNs because:
  1. CSRF tokens become stale and cause WebSocket validation failures
  2. Search results are personalized/filtered
  3. Admin dashboards show real-time data
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    # Register a before_send callback to set cache headers
    # This runs after the response is built but before it's sent
    register_before_send(conn, fn conn ->
      set_cache_headers(conn)
    end)
  end

  defp set_cache_headers(conn) do
    content_type = get_resp_header(conn, "content-type") |> List.first() || ""

    cond do
      # LiveView HTML contains session-specific connection tokens. Static
      # assets are digest-named and keep their normal cache headers.
      String.contains?(content_type, "text/html") ->
        set_no_cache_headers(conn)

      # Default - don't modify headers for non-HTML content (static files, etc.)
      true ->
        conn
    end
  end

  defp set_no_cache_headers(conn) do
    conn
    |> put_resp_header(
      "cache-control",
      "private, no-store, no-cache, must-revalidate, max-age=0"
    )
    |> put_resp_header("pragma", "no-cache")
    |> put_resp_header("expires", "-1")
  end

  @doc """
  Determines if a path should be cached by CDN.

  Cinegraph's HTML pages are LiveViews, and LiveView HTML contains per-session
  CSRF tokens. Cache static assets aggressively instead, but never cache the
  HTML documents themselves.
  """
  def cacheable_path?(_path), do: false
end

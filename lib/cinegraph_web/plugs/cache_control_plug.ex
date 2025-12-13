defmodule CinegraphWeb.Plugs.CacheControlPlug do
  @moduledoc """
  Sets appropriate cache-control headers for different route types.

  LiveView pages must not be cached by CDNs (like Cloudflare) because they contain
  CSRF tokens that become stale. Cached pages with old CSRF tokens cause infinite
  reload loops when the WebSocket connection fails validation.

  Static assets can be cached aggressively since they have fingerprinted filenames.
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
    # Only set headers for HTML responses (LiveView pages)
    # Don't override headers for static assets, API responses, etc.
    content_type = get_resp_header(conn, "content-type") |> List.first() || ""

    cond do
      # HTML pages (LiveView) - prevent CDN caching entirely
      String.contains?(content_type, "text/html") ->
        conn
        |> put_resp_header(
          "cache-control",
          "private, no-store, no-cache, must-revalidate, max-age=0"
        )
        |> put_resp_header("pragma", "no-cache")
        |> put_resp_header("expires", "-1")

      # Already has cache-control set (e.g., redirects, static files)
      get_resp_header(conn, "cache-control") != [] ->
        conn

      # Default - don't modify
      true ->
        conn
    end
  end
end

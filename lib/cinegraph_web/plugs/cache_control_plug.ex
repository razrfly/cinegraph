defmodule CinegraphWeb.Plugs.CacheControlPlug do
  @moduledoc """
  Smart cache control headers for different route types.

  ## Caching Strategy

  Content rarely changes, so we use long CDN cache times with ETag validation
  as a safety net. When Cloudflare's cache expires, it revalidates with origin
  using If-None-Match. If content unchanged (304), Cloudflare extends the cache.

  ### Cache Tiers

  **Movie/Person/List/Award Detail Pages** - Very stable content
  - `s-maxage=604800` (7 days) - CDN caches for a week
  - `stale-while-revalidate=2592000` (30 days) - Serve stale while fetching fresh
  - `max-age=300` (5 min) - Browser cache short for LiveView

  These pages change infrequently (weeks/months). The ETag is computed from
  ALL data on the page (movie + metrics + credits), so when anything changes,
  the ETag changes and Cloudflare will get fresh content on next revalidation.

  ### Non-Cacheable Pages (No CDN caching)
  - `/movies` (search page with filters)
  - `/movies/discover` (discovery page)
  - `/admin/*` (admin dashboards)
  - All other dynamic pages

  LiveView pages with dynamic content must not be cached by CDNs because:
  1. CSRF tokens become stale and cause WebSocket validation failures
  2. Search results are personalized/filtered
  3. Admin dashboards show real-time data

  ## How ETag + Long s-maxage Works

  1. First request → Origin returns page with ETag + Cache-Control
  2. For 7 days → Cloudflare serves cached content instantly (no origin hit)
  3. After 7 days → Cloudflare sends If-None-Match to origin
  4. If unchanged → Origin returns 304, Cloudflare extends cache another 7 days
  5. If changed → Origin returns 200 with new content + ETag

  This means origin only gets hit once per week per page (and returns 304 most
  of the time since content rarely changes).
  """

  import Plug.Conn

  # Cache durations (in seconds)
  # 7 days CDN cache - content rarely changes
  @cdn_max_age 604_800
  # 30 days stale-while-revalidate - serve stale while fetching fresh
  @stale_while_revalidate 2_592_000
  # 5 minutes browser cache - short for LiveView compatibility
  @browser_max_age 300

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
      # Cacheable HTML pages - allow long CDN caching
      # NOTE: We MUST set these headers even if cache-control is already set,
      # because Phoenix/Plug sets a default "max-age=0, private, must-revalidate"
      # header on all responses. We need to override this for cacheable pages.
      String.contains?(content_type, "text/html") and cacheable_path?(conn.request_path) ->
        set_cacheable_headers(conn)

      # Non-cacheable HTML pages (LiveView with dynamic content, admin, etc.)
      # For these, keep Phoenix's default no-cache behavior (or reinforce it)
      String.contains?(content_type, "text/html") ->
        # Phoenix already sets private, no-cache headers by default
        # We reinforce this to be explicit about our caching strategy
        set_no_cache_headers(conn)

      # Default - don't modify headers for non-HTML content (static files, etc.)
      true ->
        conn
    end
  end

  defp set_cacheable_headers(conn) do
    # Long CDN cache with stale-while-revalidate for instant responses
    # ETag validation (in ETagPlug) ensures fresh content when data changes
    cache_control =
      "public, max-age=#{@browser_max_age}, s-maxage=#{@cdn_max_age}, stale-while-revalidate=#{@stale_while_revalidate}"

    conn
    |> put_resp_header("cache-control", cache_control)
    |> put_resp_header("vary", "Accept-Encoding")
    |> maybe_add_cache_tag()
  end

  # Add Cache-Tag header for Cloudflare cache purging
  # This allows targeted cache invalidation when content changes
  defp maybe_add_cache_tag(conn) do
    case get_cache_tag(conn.request_path) do
      nil -> conn
      tag -> put_resp_header(conn, "cache-tag", tag)
    end
  end

  defp get_cache_tag(path) do
    case String.split(path, "/", trim: true) do
      ["movies", slug] when slug not in ["discover", "tmdb", "imdb"] ->
        "movie-#{slug}"

      ["people", slug] when slug != "tmdb" ->
        "person-#{slug}"

      ["lists", slug] ->
        "list-#{slug}"

      ["awards", slug | _rest] ->
        "award-#{slug}"

      _ ->
        nil
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

  Cacheable paths are content detail pages that:
  1. Display relatively static content (changes weeks/months apart)
  2. Have ETag validation for freshness checking
  3. Don't contain user-specific or session-specific data

  Non-cacheable paths include:
  - Search pages with query parameters
  - Admin dashboards
  - Discovery/personalized pages
  """
  def cacheable_path?(path) do
    cond do
      # Admin pages - never cache
      String.starts_with?(path, "/admin") ->
        false

      # Health/API endpoints - never cache HTML version
      String.starts_with?(path, "/health") ->
        false

      # Dev routes - never cache
      String.starts_with?(path, "/dev") ->
        false

      # Movie detail page (but not /movies or /movies/discover)
      movie_detail_path?(path) ->
        true

      # Person detail page (but not /people search)
      person_detail_path?(path) ->
        true

      # List detail page (but not /lists index)
      list_detail_path?(path) ->
        true

      # Award detail page (but not /awards index)
      award_detail_path?(path) ->
        true

      # Everything else is not cacheable
      true ->
        false
    end
  end

  # Movie detail paths: /movies/:slug but NOT:
  # - /movies (index)
  # - /movies/discover
  # - /movies/tmdb/:id (redirects, shouldn't cache)
  # - /movies/imdb/:id (redirects, shouldn't cache)
  defp movie_detail_path?(path) do
    case String.split(path, "/", trim: true) do
      ["movies", slug] when slug not in ["discover", "tmdb", "imdb"] ->
        # It's a movie detail page with a slug
        true

      _ ->
        false
    end
  end

  # Person detail paths: /people/:slug but NOT /people (index)
  defp person_detail_path?(path) do
    case String.split(path, "/", trim: true) do
      ["people", slug] when slug != "tmdb" ->
        true

      _ ->
        false
    end
  end

  # List detail paths: /lists/:slug but NOT /lists (index)
  defp list_detail_path?(path) do
    case String.split(path, "/", trim: true) do
      ["lists", _slug] ->
        true

      _ ->
        false
    end
  end

  # Award detail paths: /awards/:slug and /awards/:slug/* but NOT /awards (index)
  defp award_detail_path?(path) do
    case String.split(path, "/", trim: true) do
      ["awards", _slug] ->
        true

      ["awards", _slug, _action] ->
        true

      _ ->
        false
    end
  end
end

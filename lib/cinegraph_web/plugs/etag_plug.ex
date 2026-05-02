defmodule CinegraphWeb.Plugs.ETagPlug do
  @moduledoc """
  ETag support for HTML responses, currently disabled.

  LiveView HTML embeds per-session CSRF and socket connection params. Reusing a
  cached HTML document through conditional ETag handling can leave browsers with
  stale LiveView connection data, so this plug intentionally does not emit ETags
  or return conditional responses for any path.

  `cacheable_for_etag?/1` is the single source of truth for whether this plug may
  handle a request. It currently always returns `false`; the freshness helpers
  below are retained for a future cache strategy that can safely separate shared
  page data from session-specific LiveView HTML.
  """

  import Plug.Conn
  require Logger

  alias Cinegraph.Repo
  import Ecto.Query

  @doc false
  def init(opts), do: opts

  @doc false
  def call(conn, _opts) do
    # Only process GET requests for cacheable paths
    if conn.method == "GET" and cacheable_for_etag?(conn.request_path) do
      handle_conditional_request(conn)
    else
      conn
    end
  end

  defp handle_conditional_request(conn) do
    case get_resource_freshness(conn.request_path) do
      nil ->
        # Resource not found, continue normally
        conn

      {etag, last_modified} ->
        if_none_match = get_req_header(conn, "if-none-match") |> List.first()

        if if_none_match && etag_matches?(if_none_match, etag) do
          # Client has current version, return 304
          conn
          |> put_resp_header("etag", etag)
          |> put_resp_header("last-modified", format_http_date(last_modified))
          |> put_resp_header("cache-control", cache_control_header())
          |> send_resp(304, "")
          |> halt()
        else
          # Add ETag and Last-Modified to response via before_send callback
          register_before_send(conn, fn conn ->
            if conn.status == 200 do
              conn
              |> put_resp_header("etag", etag)
              |> put_resp_header("last-modified", format_http_date(last_modified))
            else
              conn
            end
          end)
        end
    end
  end

  defp cacheable_for_etag?(_path) do
    # LiveView HTML embeds CSRF tokens. Returning 304 would make the browser
    # reuse an old HTML document with stale LiveView connection params.
    false
  end

  defp get_resource_freshness(path) do
    case parse_resource(path) do
      {:movie, slug} ->
        get_movie_freshness(slug)

      {:person, slug} ->
        get_person_freshness(slug)

      {:list, slug} ->
        get_list_freshness(slug)

      {:award, slug} ->
        get_award_freshness(slug)

      nil ->
        nil
    end
  end

  defp parse_resource(path) do
    case String.split(path, "/", trim: true) do
      ["movies", slug] when slug not in ["discover", "tmdb", "imdb"] ->
        {:movie, slug}

      ["people", slug] when slug != "tmdb" ->
        {:person, slug}

      ["lists", slug] ->
        {:list, slug}

      ["awards", slug | _rest] ->
        {:award, slug}

      _ ->
        nil
    end
  end

  # ============================================================================
  # Movie Freshness
  # ============================================================================
  # A movie page's freshness is determined by:
  # 1. The movie record itself (updated_at)
  # 2. External metrics (fetched_at) - ratings change frequently
  # 3. Credits (updated_at) - cast/crew rarely change
  # ============================================================================

  defp get_movie_freshness(slug) do
    # Single query to get movie ID and all relevant timestamps
    query = """
    SELECT
      m.id,
      GREATEST(
        m.updated_at,
        COALESCE((SELECT MAX(em.fetched_at) FROM external_metrics em WHERE em.movie_id = m.id), m.updated_at),
        COALESCE((SELECT MAX(c.updated_at) FROM movie_credits c WHERE c.movie_id = m.id), m.updated_at)
      ) as last_modified
    FROM movies m
    WHERE m.slug = $1
    LIMIT 1
    """

    case Repo.query(query, [slug]) do
      {:ok, %{rows: [[id, last_modified]]}} when not is_nil(id) ->
        etag = generate_etag("movie", id, last_modified)
        {etag, last_modified}

      _ ->
        nil
    end
  end

  # ============================================================================
  # Person Freshness
  # ============================================================================
  # A person page's freshness is determined by:
  # 1. The person record itself (updated_at)
  # 2. Their credits (updated_at) - filmography changes
  # ============================================================================

  defp get_person_freshness(slug) do
    query = """
    SELECT
      p.id,
      GREATEST(
        p.updated_at,
        COALESCE((SELECT MAX(c.updated_at) FROM movie_credits c WHERE c.person_id = p.id), p.updated_at)
      ) as last_modified
    FROM people p
    WHERE p.slug = $1
    LIMIT 1
    """

    case Repo.query(query, [slug]) do
      {:ok, %{rows: [[id, last_modified]]}} when not is_nil(id) ->
        etag = generate_etag("person", id, last_modified)
        {etag, last_modified}

      _ ->
        nil
    end
  end

  # ============================================================================
  # List Freshness
  # ============================================================================
  # Lists are relatively static - use the list's updated_at
  # ============================================================================

  defp get_list_freshness(slug) do
    query =
      from l in "movie_lists",
        where: l.slug == ^slug,
        select: {l.id, l.updated_at},
        limit: 1

    case Repo.one(query) do
      {id, updated_at} when not is_nil(id) ->
        etag = generate_etag("list", id, updated_at)
        {etag, updated_at}

      _ ->
        nil
    end
  end

  # ============================================================================
  # Award Freshness
  # ============================================================================
  # Awards use the festival organization's updated_at or latest nomination
  # ============================================================================

  defp get_award_freshness(slug) do
    # Try to find festival organization by slug
    query =
      from fo in "festival_organizations",
        where: fo.slug == ^slug,
        select: {fo.id, fo.updated_at},
        limit: 1

    case Repo.one(query) do
      {id, updated_at} when not is_nil(id) ->
        etag = generate_etag("award", id, updated_at)
        {etag, updated_at}

      _ ->
        # Fallback: use start of current day as cache key (refreshes daily)
        today = Date.utc_today()
        midnight = DateTime.new!(today, ~T[00:00:00], "Etc/UTC")
        etag = ~s(W/"award-#{slug}-#{Date.to_iso8601(today)}")
        {etag, midnight}
    end
  end

  # ============================================================================
  # ETag Generation
  # ============================================================================

  defp generate_etag(type, id, %DateTime{} = timestamp) do
    unix = DateTime.to_unix(timestamp)
    ~s(W/"#{type}-#{id}-#{unix}")
  end

  defp generate_etag(type, id, %NaiveDateTime{} = timestamp) do
    unix = timestamp |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix()
    ~s(W/"#{type}-#{id}-#{unix}")
  end

  defp generate_etag(type, id, unix) when is_integer(unix) do
    ~s(W/"#{type}-#{id}-#{unix}")
  end

  defp etag_matches?(if_none_match, current_etag) do
    # Handle multiple ETags in If-None-Match header
    if_none_match
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.any?(fn tag ->
      tag == current_etag or tag == "*"
    end)
  end

  # ============================================================================
  # HTTP Headers
  # ============================================================================

  defp cache_control_header do
    "private, no-store, no-cache, must-revalidate, max-age=0"
  end

  defp format_http_date(%DateTime{} = datetime) do
    datetime
    |> DateTime.shift_zone!("Etc/UTC")
    |> Calendar.strftime("%a, %d %b %Y %H:%M:%S GMT")
  end

  defp format_http_date(%NaiveDateTime{} = datetime) do
    datetime
    |> DateTime.from_naive!("Etc/UTC")
    |> format_http_date()
  end

  defp format_http_date(_), do: nil
end

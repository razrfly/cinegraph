defmodule CinegraphWeb.Plugs.CacheControlPlugTest do
  use ExUnit.Case, async: true

  import Plug.Conn

  alias CinegraphWeb.Plugs.CacheControlPlug

  @no_cache_header "private, no-store, no-cache, must-revalidate, max-age=0"

  describe "cacheable_path?/1" do
    test "movie detail pages are not cacheable because they are LiveViews" do
      refute CacheControlPlug.cacheable_path?("/movies/fight-club-1999")
      refute CacheControlPlug.cacheable_path?("/movies/the-matrix-1999")
      refute CacheControlPlug.cacheable_path?("/movies/some-slug-with-numbers-123")
    end

    test "movie index and special pages are not cacheable" do
      refute CacheControlPlug.cacheable_path?("/movies")
      refute CacheControlPlug.cacheable_path?("/movies/discover")
    end

    test "movie lookup routes are not cacheable (they redirect)" do
      refute CacheControlPlug.cacheable_path?("/movies/tmdb/550")
      refute CacheControlPlug.cacheable_path?("/movies/imdb/tt0137523")
    end

    test "person detail pages are not cacheable because they are LiveViews" do
      refute CacheControlPlug.cacheable_path?("/people/tom-hanks")
      refute CacheControlPlug.cacheable_path?("/people/some-person-123")
    end

    test "person index and lookup pages are not cacheable" do
      refute CacheControlPlug.cacheable_path?("/people")
      refute CacheControlPlug.cacheable_path?("/people/tmdb/31")
    end

    test "list detail pages are not cacheable because they are LiveViews" do
      refute CacheControlPlug.cacheable_path?("/lists/1001-movies")
      refute CacheControlPlug.cacheable_path?("/lists/criterion-collection")
    end

    test "list index is not cacheable" do
      refute CacheControlPlug.cacheable_path?("/lists")
    end

    test "award detail pages are not cacheable because they are LiveViews" do
      refute CacheControlPlug.cacheable_path?("/awards/oscars")
      refute CacheControlPlug.cacheable_path?("/awards/cannes")
      refute CacheControlPlug.cacheable_path?("/awards/oscars/winners")
      refute CacheControlPlug.cacheable_path?("/awards/oscars/nominees")
    end

    test "award index is not cacheable" do
      refute CacheControlPlug.cacheable_path?("/awards")
    end

    test "admin pages are never cacheable" do
      refute CacheControlPlug.cacheable_path?("/admin")
      refute CacheControlPlug.cacheable_path?("/admin/imports")
      refute CacheControlPlug.cacheable_path?("/admin/oban")
      refute CacheControlPlug.cacheable_path?("/admin/metrics")
    end

    test "health endpoints are not cacheable" do
      refute CacheControlPlug.cacheable_path?("/health")
      refute CacheControlPlug.cacheable_path?("/health/db")
    end

    test "dev routes are not cacheable" do
      refute CacheControlPlug.cacheable_path?("/dev/dashboard")
      refute CacheControlPlug.cacheable_path?("/dev/mailbox")
    end

    test "root and other pages are not cacheable" do
      refute CacheControlPlug.cacheable_path?("/")
      refute CacheControlPlug.cacheable_path?("/collaborations")
      refute CacheControlPlug.cacheable_path?("/six-degrees")
    end
  end

  describe "call/2 header behavior" do
    test "sets no-cache headers on HTML responses" do
      conn =
        :get
        |> Plug.Test.conn("/movies/fight-club-1999")
        |> put_req_header("accept", "text/html")
        |> put_resp_content_type("text/html")
        |> CacheControlPlug.call([])
        |> send_resp(200, "<html></html>")

      assert [@no_cache_header] = get_resp_header(conn, "cache-control")
      assert ["no-cache"] = get_resp_header(conn, "pragma")
      assert ["-1"] = get_resp_header(conn, "expires")
    end

    test "does not override cache headers on non-HTML responses" do
      conn =
        :get
        |> Plug.Test.conn("/api/movies")
        |> put_req_header("accept", "application/json")
        |> put_resp_content_type("application/json")
        |> put_resp_header("cache-control", "public, max-age=60")
        |> CacheControlPlug.call([])
        |> send_resp(200, ~s({"ok":true}))

      assert ["public, max-age=60"] = get_resp_header(conn, "cache-control")
      assert [] = get_resp_header(conn, "pragma")
      assert [] = get_resp_header(conn, "expires")
    end
  end
end

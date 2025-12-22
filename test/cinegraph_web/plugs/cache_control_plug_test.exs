defmodule CinegraphWeb.Plugs.CacheControlPlugTest do
  use ExUnit.Case, async: true

  alias CinegraphWeb.Plugs.CacheControlPlug

  describe "cacheable_path?/1" do
    test "movie detail pages are cacheable" do
      assert CacheControlPlug.cacheable_path?("/movies/fight-club-1999")
      assert CacheControlPlug.cacheable_path?("/movies/the-matrix-1999")
      assert CacheControlPlug.cacheable_path?("/movies/some-slug-with-numbers-123")
    end

    test "movie index and special pages are not cacheable" do
      refute CacheControlPlug.cacheable_path?("/movies")
      refute CacheControlPlug.cacheable_path?("/movies/discover")
    end

    test "movie lookup routes are not cacheable (they redirect)" do
      refute CacheControlPlug.cacheable_path?("/movies/tmdb/550")
      refute CacheControlPlug.cacheable_path?("/movies/imdb/tt0137523")
    end

    test "person detail pages are cacheable" do
      assert CacheControlPlug.cacheable_path?("/people/tom-hanks")
      assert CacheControlPlug.cacheable_path?("/people/some-person-123")
    end

    test "person index and lookup pages are not cacheable" do
      refute CacheControlPlug.cacheable_path?("/people")
      refute CacheControlPlug.cacheable_path?("/people/tmdb/31")
    end

    test "list detail pages are cacheable" do
      assert CacheControlPlug.cacheable_path?("/lists/1001-movies")
      assert CacheControlPlug.cacheable_path?("/lists/criterion-collection")
    end

    test "list index is not cacheable" do
      refute CacheControlPlug.cacheable_path?("/lists")
    end

    test "award detail pages are cacheable" do
      assert CacheControlPlug.cacheable_path?("/awards/oscars")
      assert CacheControlPlug.cacheable_path?("/awards/cannes")
      assert CacheControlPlug.cacheable_path?("/awards/oscars/winners")
      assert CacheControlPlug.cacheable_path?("/awards/oscars/nominees")
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
end

defmodule CinegraphWeb.Helpers.WombieLinksTest do
  use ExUnit.Case, async: false

  alias CinegraphWeb.Helpers.WombieLinks

  @movie %{slug: "inception", tmdb_id: 27_205}

  test "builds slug-based URL with default now_playing campaign" do
    url = WombieLinks.showtimes_url(@movie)
    assert url =~ "wombie.com/movies/inception-27205"
    assert url =~ "utm_campaign=now_playing"
    assert url =~ "utm_source=cinegraph"
    assert url =~ "utm_medium=referral"
  end

  test "uses provided campaign" do
    url = WombieLinks.showtimes_url(@movie, "movie_show")
    assert url =~ "utm_campaign=movie_show"
  end

  test "graphql campaign" do
    url = WombieLinks.showtimes_url(@movie, "graphql")
    assert url =~ "utm_campaign=graphql"
  end

  test "returns nil when slug is nil" do
    assert WombieLinks.showtimes_url(%{slug: nil, tmdb_id: 27_205}) == nil
  end

  test "returns nil when slug is empty string" do
    assert WombieLinks.showtimes_url(%{slug: "", tmdb_id: 27_205}) == nil
  end

  test "builds homepage URL with UTM attribution" do
    url = WombieLinks.homepage_url("now_playing_footer")
    assert url =~ "wombie.com"
    assert url =~ "utm_campaign=now_playing_footer"
    assert url =~ "utm_source=cinegraph"
    assert url =~ "utm_medium=referral"
  end

  test "trims trailing slash from base URL" do
    Application.put_env(:cinegraph, :wombie_base_url, "https://wombie.com/")
    url = WombieLinks.showtimes_url(@movie)
    refute url =~ "wombie.com//movies"
    assert url =~ "wombie.com/movies/inception-27205"
  after
    Application.delete_env(:cinegraph, :wombie_base_url)
  end

  test "uses configured base URL" do
    Application.put_env(:cinegraph, :wombie_base_url, "https://staging.wombie.com")
    url = WombieLinks.showtimes_url(@movie)
    assert url =~ "staging.wombie.com/movies/inception-27205"
  after
    Application.delete_env(:cinegraph, :wombie_base_url)
  end
end

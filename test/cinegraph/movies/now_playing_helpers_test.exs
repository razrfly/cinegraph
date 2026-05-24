defmodule Cinegraph.Movies.NowPlayingHelpersTest do
  use ExUnit.Case, async: true

  alias Cinegraph.Movies
  alias Cinegraph.Movies.Movie

  defp movie_with_regions(regions_map) do
    %Movie{now_playing_region_last_seen: regions_map}
  end

  defp fresh_ts, do: DateTime.utc_now() |> DateTime.to_iso8601()
  defp stale_ts, do: DateTime.add(DateTime.utc_now(), -4, :day) |> DateTime.to_iso8601()

  describe "active_now_playing_regions/2" do
    test "returns empty list when field is nil" do
      movie = %Movie{now_playing_region_last_seen: nil}
      assert Movies.active_now_playing_regions(movie) == []
    end

    test "returns empty list when map is empty" do
      movie = movie_with_regions(%{})
      assert Movies.active_now_playing_regions(movie) == []
    end

    test "returns fresh regions only" do
      movie = movie_with_regions(%{"US" => fresh_ts(), "DE" => stale_ts()})
      assert Movies.active_now_playing_regions(movie) == ["US"]
    end

    test "returns all fresh regions when all are current" do
      movie = movie_with_regions(%{"US" => fresh_ts(), "GB" => fresh_ts()})
      result = Movies.active_now_playing_regions(movie)
      assert "US" in result
      assert "GB" in result
    end

    test "returns empty when all regions are stale" do
      movie = movie_with_regions(%{"US" => stale_ts(), "GB" => stale_ts()})
      assert Movies.active_now_playing_regions(movie) == []
    end

    test "respects custom cutoff" do
      two_days_ago = DateTime.add(DateTime.utc_now(), -2, :day) |> DateTime.to_iso8601()
      movie = movie_with_regions(%{"US" => two_days_ago})

      one_day_cutoff = DateTime.add(DateTime.utc_now(), -1, :day)
      three_day_cutoff = DateTime.add(DateTime.utc_now(), -3, :day)

      assert Movies.active_now_playing_regions(movie, one_day_cutoff) == []
      assert Movies.active_now_playing_regions(movie, three_day_cutoff) == ["US"]
    end
  end

  describe "currently_in_theaters?/2" do
    test "returns false when field is nil" do
      movie = %Movie{now_playing_region_last_seen: nil}
      refute Movies.currently_in_theaters?(movie)
    end

    test "returns true when any region is fresh" do
      movie = movie_with_regions(%{"US" => fresh_ts(), "DE" => stale_ts()})
      assert Movies.currently_in_theaters?(movie)
    end

    test "returns false when all regions are stale" do
      movie = movie_with_regions(%{"US" => stale_ts()})
      refute Movies.currently_in_theaters?(movie)
    end
  end

  describe "region_active?/3" do
    test "returns false for a region not in the map" do
      movie = movie_with_regions(%{"US" => fresh_ts()})
      refute Movies.region_active?(movie, "DE")
    end

    test "returns true for a fresh region" do
      movie = movie_with_regions(%{"US" => fresh_ts()})
      assert Movies.region_active?(movie, "US")
    end

    test "returns false for a stale region" do
      movie = movie_with_regions(%{"US" => stale_ts()})
      refute Movies.region_active?(movie, "US")
    end

    test "returns false when field is nil" do
      movie = %Movie{now_playing_region_last_seen: nil}
      refute Movies.region_active?(movie, "US")
    end
  end
end

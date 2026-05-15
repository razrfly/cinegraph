defmodule CinegraphWeb.MovieLive.ShowV2.PresentationTest do
  # Pure-function tests — no DB needed. The functions under test operate on
  # in-memory lists in the shape ExternalSources.get_movie_metrics/2 and
  # get_movie_ratings/1 produce.
  use ExUnit.Case, async: true

  alias CinegraphWeb.MovieLive.ShowV2.Presentation

  describe "rating_value/3" do
    test "finds a row by source_key + metric_type (#913 wiring-bug regression guard)" do
      # Shape mirrors ExternalSources.get_movie_ratings/1 — post-#913 the key is
      # :metric_type, not :rating_type. If the rename ever regresses, this fails.
      ratings = [
        %{metric_type: "rating_average", value: 8.5, source: %{name: "imdb", id: nil}},
        %{metric_type: "tomatometer", value: 95, source: %{name: "rotten_tomatoes", id: nil}}
      ]

      assert %{value: 8.5} = Presentation.rating_value(ratings, "imdb")
      assert %{value: 95} = Presentation.rating_value(ratings, "rotten_tomatoes", "tomatometer")
    end

    test "returns nil when no row matches source + type" do
      ratings = [
        %{metric_type: "rating_average", value: 8.5, source: %{name: "imdb", id: nil}}
      ]

      assert Presentation.rating_value(ratings, "metacritic") == nil
      assert Presentation.rating_value(ratings, "imdb", "tomatometer") == nil
    end
  end

  describe "content_rating/1" do
    test "returns text_value from the omdb/content_rating metric" do
      metrics = [
        %{metric_type: "content_rating", text_value: "PG-13", source: %{name: "omdb", id: nil}}
      ]

      assert Presentation.content_rating(metrics) == "PG-13"
    end

    test "is independent of other metric_types in the list" do
      metrics = [
        %{
          metric_type: "awards_summary",
          text_value: "Won 2 Oscars",
          source: %{name: "omdb", id: nil}
        },
        %{metric_type: "content_rating", text_value: "R", source: %{name: "omdb", id: nil}}
      ]

      assert Presentation.content_rating(metrics) == "R"
    end

    test "returns nil when no content_rating row exists" do
      metrics = [
        %{
          metric_type: "awards_summary",
          text_value: "Won 2 Oscars",
          source: %{name: "omdb", id: nil}
        }
      ]

      assert Presentation.content_rating(metrics) == nil
    end

    test "returns nil for empty list" do
      assert Presentation.content_rating([]) == nil
    end

    test "returns nil when text_value is empty string" do
      metrics = [
        %{metric_type: "content_rating", text_value: "", source: %{name: "omdb", id: nil}}
      ]

      assert Presentation.content_rating(metrics) == nil
    end

    test "returns nil when text_value is the OMDb N/A sentinel" do
      metrics = [
        %{metric_type: "content_rating", text_value: "N/A", source: %{name: "omdb", id: nil}}
      ]

      assert Presentation.content_rating(metrics) == nil
    end

    test "returns nil when input is not a list (no JSONB fallback)" do
      # Catches regression where a caller passes @movie instead of @metrics.
      assert Presentation.content_rating(%{omdb_data: %{"Rated" => "PG-13"}}) == nil
      assert Presentation.content_rating(nil) == nil
    end
  end

  describe "omdb_awards/1" do
    test "returns text_value from the omdb/awards_summary metric" do
      metrics = [
        %{
          metric_type: "awards_summary",
          text_value: "Won 7 Oscars",
          source: %{name: "omdb", id: nil}
        }
      ]

      assert Presentation.omdb_awards(metrics) == "Won 7 Oscars"
    end

    test "returns nil when no awards_summary row exists" do
      metrics = [
        %{metric_type: "content_rating", text_value: "PG-13", source: %{name: "omdb", id: nil}}
      ]

      assert Presentation.omdb_awards(metrics) == nil
    end

    test "returns nil when text_value is empty" do
      metrics = [
        %{metric_type: "awards_summary", text_value: "", source: %{name: "omdb", id: nil}}
      ]

      assert Presentation.omdb_awards(metrics) == nil
    end

    test "returns nil when text_value is the OMDb N/A sentinel" do
      metrics = [
        %{metric_type: "awards_summary", text_value: "N/A", source: %{name: "omdb", id: nil}}
      ]

      assert Presentation.omdb_awards(metrics) == nil
    end

    test "returns nil for empty list or non-list input" do
      assert Presentation.omdb_awards([]) == nil
      assert Presentation.omdb_awards(%{omdb_data: %{"Awards" => "Won 2"}}) == nil
      assert Presentation.omdb_awards(nil) == nil
    end
  end
end

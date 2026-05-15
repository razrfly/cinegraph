defmodule CinegraphWeb.RatingComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias CinegraphWeb.RatingComponents

  # `hero_ratings_row/1` calls into private `build_hero_ratings/1`, so testing
  # the rendered component covers the migration from JSONB → external_ratings
  # without exposing private functions.

  describe "hero_ratings_row/1 (#913 PR A pt 2 — reads external_ratings only)" do
    test "renders badges for imdb / tmdb / rotten_tomatoes / metacritic from external_ratings" do
      movie = %{
        imdb_id: "tt0111161",
        tmdb_id: 278,
        external_ratings: [
          %{
            metric_type: "rating_average",
            value: 9.3,
            metadata: %{},
            source: %{name: "imdb", id: nil}
          },
          %{
            metric_type: "rating_average",
            value: 8.7,
            metadata: %{},
            source: %{name: "tmdb", id: nil}
          },
          %{
            metric_type: "tomatometer",
            value: 91.0,
            metadata: %{},
            source: %{name: "rotten_tomatoes", id: nil}
          },
          %{
            metric_type: "metascore",
            value: 82.0,
            metadata: %{},
            source: %{name: "metacritic", id: nil}
          }
        ]
      }

      html = render_component(&RatingComponents.hero_ratings_row/1, movie: movie)

      # IMDb URL is derived from imdb_id, not omdb_data
      assert html =~ "https://www.imdb.com/title/tt0111161/"
      # TMDb URL is derived from tmdb_id
      assert html =~ "https://www.themoviedb.org/movie/278"
      # Each source's name appears in the hover popover
      assert html =~ "IMDb"
      assert html =~ "TMDb"
      assert html =~ "Tomatometer"
      assert html =~ "Metacritic"
    end

    test "returns empty output when external_ratings is empty" do
      movie = %{imdb_id: nil, tmdb_id: nil, external_ratings: []}
      html = render_component(&RatingComponents.hero_ratings_row/1, movie: movie)
      # The component returns "" when there are no ratings → no badge markup
      refute html =~ "inline-flex"
    end

    test "rejects zero values" do
      movie = %{
        imdb_id: nil,
        tmdb_id: 1,
        external_ratings: [
          %{
            metric_type: "rating_average",
            value: 0.0,
            metadata: %{},
            source: %{name: "tmdb", id: nil}
          },
          %{
            metric_type: "rating_average",
            value: 7.5,
            metadata: %{},
            source: %{name: "imdb", id: nil}
          }
        ]
      }

      html = render_component(&RatingComponents.hero_ratings_row/1, movie: movie)

      # IMDb at 7.5 renders
      assert html =~ "7.5/10"
      # TMDb at 0.0 is rejected — its hover popover should not appear
      # (look for the TMDb name in popover, which only shows when rendered)
      refute html =~ ~s(<span class="font-bold text-sm">TMDb</span>)
    end

    test "is resilient when movie has no external_ratings key at all" do
      movie = %{imdb_id: nil, tmdb_id: nil}
      html = render_component(&RatingComponents.hero_ratings_row/1, movie: movie)
      refute html =~ "inline-flex"
    end

    test "deduplicates by source when multiple metrics share a source name" do
      # If external_ratings had two rows for the same source (e.g., a duplicate
      # rating_votes / rating_average pair both normalizing to "imdb"), only
      # one badge should render.
      movie = %{
        imdb_id: "tt0000001",
        tmdb_id: nil,
        external_ratings: [
          %{
            metric_type: "rating_average",
            value: 8.0,
            metadata: %{},
            source: %{name: "imdb", id: nil}
          },
          %{
            metric_type: "rating_average",
            value: 9.0,
            metadata: %{},
            source: %{name: "imdb", id: nil}
          }
        ]
      }

      html = render_component(&RatingComponents.hero_ratings_row/1, movie: movie)
      # Count occurrences of the IMDb URL — should appear once per badge
      occurrences =
        html
        |> String.split("https://www.imdb.com/title/tt0000001/")
        |> length()
        |> Kernel.-(1)

      assert occurrences == 1
    end

    test "keeps Rotten Tomatoes audience score separate from tomatometer for raw source names" do
      movie = %{
        imdb_id: nil,
        tmdb_id: nil,
        external_ratings: [
          %{
            metric_type: "tomatometer",
            value: 91.0,
            metadata: %{},
            source: %{name: "Rotten Tomatoes", id: nil}
          },
          %{
            metric_type: "audience_score",
            value: 88.0,
            metadata: %{},
            source: %{name: "Rotten Tomatoes", id: nil}
          }
        ]
      }

      html = render_component(&RatingComponents.hero_ratings_row/1, movie: movie)

      assert html =~ "Tomatometer"
      assert html =~ "Audience Score"
      assert html =~ "91%"
      assert html =~ "88%"
    end
  end
end

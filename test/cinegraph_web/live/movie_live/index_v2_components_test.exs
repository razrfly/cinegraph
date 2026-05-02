defmodule CinegraphWeb.MovieLive.IndexV2ComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest
  import CinegraphWeb.MovieLive.IndexV2Components

  alias Cinegraph.Movies.{Credit, Genre, Movie, MovieScoreCache, MovieScoreability, Person}
  alias CinegraphWeb.MovieLive.GenreEmoji

  describe "results/1" do
    test "builds film cards with director data from loaded movie credits" do
      movie = %Movie{
        id: 42,
        title: "The Apartment",
        release_date: ~D[1960-06-21],
        slug: "the-apartment-1960",
        genres: [%Genre{name: "Comedy"}, %Genre{name: "Drama"}],
        movie_credits: [
          %Credit{job: "Producer", person: %Person{name: "I. A. L. Diamond"}},
          %Credit{job: "Director", person: %Person{name: "Billy Wilder"}}
        ]
      }

      html = render_component(&results/1, movies: [movie])
      {:ok, document} = Floki.parse_document(html)

      # Issue #792: cards now link to the clean /movies/:slug primary URL
      assert Floki.attribute(document, "a", "href") == ["/movies/the-apartment-1960"]
      assert Floki.text(document) =~ "The Apartment"
      assert Floki.text(document) =~ "Billy Wilder"

      [poster_src] = Floki.attribute(document, "img", "src")
      decoded_poster = URI.decode(poster_src)

      assert decoded_poster =~ "The"
      assert decoded_poster =~ "Apartment"
      assert decoded_poster =~ "BILLY WILDER"
    end

    test "normalizes cached lens scores from 0-10 scale" do
      movie = %Movie{
        id: 43,
        title: "Lens Movie",
        release_date: ~D[2024-01-01],
        slug: "lens-movie-2024",
        score_cache: %MovieScoreCache{
          mob_score: 0.8,
          critics_score: 1.0,
          festival_recognition_score: 6.2,
          time_machine_score: 0.4,
          auteurs_score: 7.1
        }
      }

      html = render_component(&results/1, movies: [movie], active_lens_key: "mob")

      assert html =~ "8%"
      assert html =~ "10%"
      refute html =~ "80%"
      refute html =~ "100%"
    end

    test "renders scoreability states for public CineGraph card scores" do
      scoreable = %Movie{
        id: 44,
        title: "Scoreable Movie",
        release_date: ~D[2020-01-01],
        slug: "scoreable-movie-2020",
        scoreability: %MovieScoreability{
          cinegraph_display_score: 8.4,
          scoreability_state: "scoreable",
          score_confidence_label: "high",
          present_lens_count: 5,
          missing_lens_count: 1,
          present_lens_labels: ~w(mob critics festival_recognition time_machine auteurs),
          missing_lens_labels: ~w(box_office)
        }
      }

      limited = %Movie{
        id: 45,
        title: "Limited Movie",
        release_date: ~D[2021-01-01],
        slug: "limited-movie-2021",
        scoreability: %MovieScoreability{
          cinegraph_display_score: 6.8,
          scoreability_state: "limited",
          score_confidence_label: "low",
          present_lens_count: 2,
          missing_lens_count: 4,
          present_lens_labels: ~w(mob critics),
          missing_lens_labels: ~w(festival_recognition time_machine auteurs box_office)
        }
      }

      insufficient = %Movie{
        id: 46,
        title: "Sparse Movie",
        release_date: ~D[2022-01-01],
        slug: "sparse-movie-2022",
        scoreability: %MovieScoreability{
          cinegraph_display_score: nil,
          scoreability_state: "insufficient_evidence",
          score_confidence_label: "insufficient",
          present_lens_count: 1,
          missing_lens_count: 5,
          present_lens_labels: ~w(critics),
          missing_lens_labels: ~w(mob festival_recognition time_machine auteurs box_office)
        }
      }

      html = render_component(&results/1, movies: [scoreable, limited, insufficient])

      assert html =~ "8.4"
      assert html =~ "6.8"
      assert html =~ "High confidence · 5 of 6 evidence lenses"
      assert html =~ "Limited confidence · 2 of 6 evidence lenses"
      assert html =~ "Not enough evidence yet"
    end
  end

  describe "active_filters/1" do
    test "does not raise on malformed genre or festival IDs" do
      html =
        render_component(&active_filters/1,
          params: %{"genres" => ["abc"], "festivals" => ["bad"]},
          filter_options: %{genres: [%Genre{id: 1, name: "Drama"}], festivals: []},
          sort_options: []
        )

      assert html =~ "abc"
      assert html =~ "bad"
    end

    test "uses provided sort options when rendering the sort chip" do
      html =
        render_component(&active_filters/1,
          params: %{"sort" => "critics_desc"},
          filter_options: %{},
          sort_options: [%{value: "critics", label: "Critics"}]
        )

      assert html =~ "Sort:"
      assert html =~ "Critics"
      assert html =~ "↓"
    end
  end

  describe "active_filter_count/1" do
    test "counts non-default sort chips" do
      assert active_filter_count(%{}) == 0
      assert active_filter_count(%{"sort" => "release_date_desc"}) == 0
      assert active_filter_count(%{"sort" => "critics_desc"}) == 1
      assert active_filter_count(%{"sort" => "critics_desc", "decade" => "1990"}) == 2
    end
  end

  describe "GenreEmoji.for_id/1" do
    test "maps known TMDb genre ids and falls back for unknown ids" do
      assert GenreEmoji.for_id(18) == "🎭"
      assert GenreEmoji.for_id("35") == "😂"
      assert GenreEmoji.for_id(999_999) == "🎞️"
      assert GenreEmoji.for_id("not-an-id") == "🎞️"
      assert GenreEmoji.for_id(nil) == "🎞️"
    end
  end
end

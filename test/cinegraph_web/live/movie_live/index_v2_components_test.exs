defmodule CinegraphWeb.MovieLive.IndexV2ComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest
  import CinegraphWeb.MovieLive.IndexV2Components

  alias Cinegraph.Movies.{Credit, Genre, Movie, MovieScoreCache, Person}

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

      assert Floki.attribute(document, "a", "href") == ["/movies-v2/the-apartment-1960"]
      assert Floki.text(document) =~ "The Apartment"
      assert Floki.text(document) =~ "Billy Wilder"

      [poster_src] = Floki.attribute(document, "img", "src")
      decoded_poster = URI.decode(poster_src)

      assert decoded_poster =~ "The"
      assert decoded_poster =~ "Apartment"
      assert decoded_poster =~ "BILLY WILDER"
    end

    test "normalizes lens scores from either 0-10 or 0-1 scale" do
      movie = %Movie{
        id: 43,
        title: "Lens Movie",
        release_date: ~D[2024-01-01],
        slug: "lens-movie-2024",
        score_cache: %MovieScoreCache{
          mob_score: 8.4,
          critics_score: 0.79,
          festival_recognition_score: 6.2,
          time_machine_score: 0.58,
          auteurs_score: 7.1
        }
      }

      html = render_component(&results/1, movies: [movie], active_lens_key: "mob")

      assert html =~ "84%"
      assert html =~ "79%"
    end
  end

  describe "active_filters/1" do
    test "does not raise on malformed genre or festival IDs" do
      html =
        render_component(&active_filters/1,
          params: %{"genres" => ["abc"], "festivals" => ["bad"]},
          filter_options: %{genres: [%Genre{id: 1, name: "Drama"}], festivals: []}
        )

      assert html =~ "abc"
      assert html =~ "bad"
    end
  end
end

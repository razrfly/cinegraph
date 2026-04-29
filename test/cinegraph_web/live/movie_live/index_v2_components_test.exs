defmodule CinegraphWeb.MovieLive.IndexV2ComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest
  import CinegraphWeb.MovieLive.IndexV2Components

  alias Cinegraph.Movies.{Credit, Genre, Movie, Person}

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
  end
end

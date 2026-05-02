defmodule CinegraphWeb.SEOHelpersTest do
  use ExUnit.Case, async: true

  import CinegraphWeb.SEOHelpers

  alias Cinegraph.Festivals.FestivalOrganization
  alias Cinegraph.Movies.{Movie, Person}

  describe "assign_movie_seo/2" do
    test "assigns movie metadata with Movie and BreadcrumbList JSON-LD" do
      movie = %Movie{
        id: 1,
        title: "The Matrix",
        original_title: "The Matrix",
        slug: "the-matrix-1999",
        overview: "A hacker discovers the nature of reality.",
        release_date: ~D[1999-03-31],
        poster_path: "/poster.jpg",
        backdrop_path: "/backdrop.jpg"
      }

      assigns = socket_assigns(assign_movie_seo(socket(), movie))

      assert assigns.page_title == "The Matrix"
      assert assigns.meta_title == "The Matrix (1999)"
      assert assigns.meta_type == "video.movie"
      assert assigns.canonical_url == "https://cinegraph.org/movies/the-matrix-1999"
      assert assigns.meta_image == "https://image.tmdb.org/t/p/w1280/backdrop.jpg"
      assert json_ld_types(assigns) == ["Movie", "BreadcrumbList"]
    end

    test "falls back when a movie has no overview or image" do
      movie = %Movie{id: 2, title: "Untitled Film", slug: "untitled-film"}

      assigns = socket_assigns(assign_movie_seo(socket(), movie))

      assert assigns.meta_description =~ "Explore Untitled Film"
      refute Map.has_key?(assigns, :meta_image)
      assert json_ld_types(assigns) == ["Movie", "BreadcrumbList"]
    end
  end

  describe "assign_person_seo/2" do
    test "assigns person metadata with Person and BreadcrumbList JSON-LD" do
      person = %Person{
        id: 1,
        name: "Carrie-Anne Moss",
        slug: "carrie-anne-moss",
        biography: "Canadian actor known for science fiction and action cinema.",
        profile_path: "/profile.jpg",
        known_for_department: "Acting"
      }

      assigns = socket_assigns(assign_person_seo(socket(), person))

      assert assigns.page_title == "Carrie-Anne Moss"
      assert assigns.meta_title == "Carrie-Anne Moss"
      assert assigns.meta_type == "profile"
      assert assigns.canonical_url == "https://cinegraph.org/people/carrie-anne-moss"
      assert assigns.meta_image == "https://image.tmdb.org/t/p/w500/profile.jpg"
      assert json_ld_types(assigns) == ["Person", "BreadcrumbList"]
    end

    test "uses a person description fallback and omits missing image" do
      person = %Person{
        id: 2,
        name: "No Bio Person",
        slug: "no-bio-person",
        known_for_department: "Directing"
      }

      assigns = socket_assigns(assign_person_seo(socket(), person))

      assert assigns.meta_description =~ "known for Directing"
      refute Map.has_key?(assigns, :meta_image)
      assert json_ld_types(assigns) == ["Person", "BreadcrumbList"]
    end
  end

  describe "collection helpers" do
    test "assign_curated_list_seo/3 emits ItemList and BreadcrumbList" do
      list_info = %{
        slug: "criterion-collection",
        name: "Criterion Collection",
        description: "Important classic and contemporary films.",
        hero_image_url: nil,
        cover_image_url: nil
      }

      movies = [
        %Movie{id: 1, title: "Seven Samurai", slug: "seven-samurai", poster_path: "/seven.jpg"}
      ]

      assigns = socket_assigns(assign_curated_list_seo(socket(), list_info, movies))

      assert assigns.meta_title == "Criterion Collection"
      assert assigns.canonical_url == "https://cinegraph.org/lists/criterion-collection"
      assert assigns.meta_image == "https://image.tmdb.org/t/p/w780/seven.jpg"
      assert json_ld_types(assigns) == ["ItemList", "BreadcrumbList"]
    end

    test "assign_awards_seo/4 emits mode-specific URLs and schema" do
      organization = %FestivalOrganization{
        id: 1,
        slug: "academy-awards",
        name: "Academy Awards"
      }

      movies = [
        %Movie{id: 1, title: "Moonlight", slug: "moonlight", poster_path: "/moonlight.jpg"}
      ]

      all_assigns = socket_assigns(assign_awards_seo(socket(), organization, :all, movies))
      winner_assigns = socket_assigns(assign_awards_seo(socket(), organization, :winners, movies))

      nominee_assigns =
        socket_assigns(assign_awards_seo(socket(), organization, :nominees, movies))

      assert all_assigns.meta_title == "Academy Awards"
      assert all_assigns.canonical_url == "https://cinegraph.org/awards/academy-awards"
      assert winner_assigns.meta_title == "Academy Awards Winners"
      assert winner_assigns.canonical_url == "https://cinegraph.org/awards/academy-awards/winners"
      assert nominee_assigns.meta_title == "Academy Awards Nominees"

      assert nominee_assigns.canonical_url ==
               "https://cinegraph.org/awards/academy-awards/nominees"

      assert json_ld_types(winner_assigns) == ["ItemList", "BreadcrumbList"]
    end
  end

  defp json_ld_types(assigns) do
    Enum.map(assigns.json_ld, & &1["@type"])
  end

  defp socket, do: %Phoenix.LiveView.Socket{}
  defp socket_assigns(socket), do: socket.assigns
end

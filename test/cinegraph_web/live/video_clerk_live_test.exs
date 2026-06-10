defmodule CinegraphWeb.VideoClerkLiveTest do
  use CinegraphWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Cinegraph.Movies.Movie
  alias Cinegraph.Repo

  test "renders the Video Clerk page with manifesto copy", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/admin/video-clerk")

    assert html =~ "The Video Clerk"
    assert html =~ "Three films in. One human-feeling recommendation out."
    assert html =~ "Against the bubble"
    assert html =~ "400 Greatest Cult Movies"
    assert html =~ "1001 Movies You Must See Before You Die"
    assert html =~ "Search for a film"
    assert html =~ "Load demo trio"
  end

  test "renders linked movie shelves from canonical list data", %{conn: conn} do
    cult = insert_movie!("Repo Man", "cult_movies_400", 2)
    canon = insert_movie!("Bicycle Thieves", "1001_movies", 1)

    {:ok, _view, html} = live(conn, ~p"/admin/video-clerk")

    assert html =~ cult.title
    assert html =~ canon.title
    assert html =~ ~s(href="/movies/#{cult.slug}")
    assert html =~ ~s(href="/movies/#{canon.slug}")
  end

  test "preselects seed movies from URL params and renders a live recommendation", %{conn: conn} do
    seed = insert_movie!("Donnie Darko", "1001_movies", 1)
    pick = insert_movie!("Harold and Maude", "cult_movies_400", 2)

    {:ok, _view, html} = live(conn, ~p"/admin/video-clerk?seed=#{seed.slug}")

    assert html =~ seed.title
    assert html =~ pick.title
    assert html =~ "is the clerk&#39;s move"
  end

  test "searches, selects, and resets movies", %{conn: conn} do
    seed = insert_movie!("Searchable Clerk Seed", "1001_movies", 1)
    pick = insert_movie!("Searchable Clerk Pick", "cult_movies_400", 2)

    {:ok, view, _html} = live(conn, ~p"/admin/video-clerk")

    html = render_change(view, "search_movies", %{"q" => "Searchable Clerk Seed"})
    assert html =~ seed.title

    html = render_click(view, "select_movie", %{"slug" => to_string(seed.slug)})
    assert html =~ pick.title

    html = render_click(view, "reset_clerk")
    assert html =~ "The clerk is waiting"
  end

  defp insert_movie!(title, source_key, position) do
    attrs = %{
      tmdb_id: System.unique_integer([:positive]),
      title: title,
      original_title: title,
      release_date: ~D[1984-01-01],
      import_status: "full",
      poster_path: "/poster.jpg",
      canonical_sources: %{
        source_key => %{
          "included" => true,
          "list_position" => position,
          "source_name" => source_key
        }
      }
    }

    %Movie{}
    |> Movie.changeset(attrs)
    |> Repo.insert!()
  end
end

defmodule CinegraphWeb.MovieLive.ShowV2VideoClerkTest do
  use CinegraphWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Cinegraph.Movies.Movie
  alias Cinegraph.Repo

  test "movie show page renders the Video Clerk module linking to the public now-playing page", %{
    conn: conn
  } do
    seed = insert_movie!("Clerk Source Movie", %{})

    _pick =
      insert_movie!("Clerk Candidate Movie", %{
        canonical_sources: %{"cult_movies_400" => %{"included" => true}}
      })

    {:ok, view, _html} = live(conn, ~p"/movies/#{seed.slug}")
    html = render_async(view)

    assert html =~ "Ask the Video Clerk"
    assert html =~ ~s(href="/now-playing")
    assert html =~ "Clerk Candidate Movie"
  end

  defp insert_movie!(title, attrs) do
    defaults = %{
      tmdb_id: System.unique_integer([:positive]),
      title: title,
      original_title: title,
      release_date: ~D[1984-01-01],
      import_status: "full",
      canonical_sources: %{}
    }

    %Movie{}
    |> Movie.changeset(Map.merge(defaults, Map.new(attrs)))
    |> Repo.insert!()
  end
end

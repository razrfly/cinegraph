defmodule CinegraphWeb.MovieLive.ShowV2RouteTest do
  @moduledoc """
  Smoke tests for the show-page route promotion (issue #792):

  - `/movies/:slug` renders the V2 show page (`MovieLive.ShowV2`).
  - `/movies/:slug/legacy` renders the V1 show page (`MovieLive.Show`).
  - `/movies-v2/:slug` is kept as an alias and also renders V2.

  Doesn't drill into either page's content beyond a couple of distinguishing
  markers — full rendering is covered by the LiveViews' own tests.
  """
  use CinegraphWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Cinegraph.Movies.Movie
  alias Cinegraph.Repo

  defp insert_movie!(attrs) do
    defaults = %{
      tmdb_id: System.unique_integer([:positive]),
      title: "Show Promotion Test #{System.unique_integer()}",
      original_title: "Show Promotion Test",
      release_date: ~D[2020-06-01]
    }

    %Movie{}
    |> Movie.changeset(Map.merge(defaults, attrs))
    |> Repo.insert!()
  end

  setup do
    Cachex.clear(:movies_cache)
    Cachex.clear(:filter_options_cache)
    movie = insert_movie!(%{title: "Routing Smoke Title"})
    %{movie: movie}
  end

  describe "/movies/:slug — V2 primary" do
    test "renders the V2 show page", %{conn: conn, movie: movie} do
      {:ok, _view, html} = live(conn, ~p"/movies/#{movie.slug}")
      # V2-specific marker: the bottom-right escape-hatch pill (#792)
      assert html =~ "Old movie page"
      assert html =~ ~p"/movies/#{movie.slug}/legacy"
      assert html =~ movie.title
    end

    test "falls back to numeric ID routes for movies without slugs", %{conn: conn, movie: movie} do
      movie =
        movie
        |> Ecto.Changeset.change(slug: nil)
        |> Repo.update!()

      {:ok, _view, html} = live(conn, ~p"/movies/#{movie.id}")
      assert html =~ "Old movie page"
      assert html =~ ~p"/movies/#{movie.id}/legacy"
      assert html =~ movie.title
    end

    test "falls back to numeric ID legacy links for movies with empty slugs", %{
      conn: conn,
      movie: movie
    } do
      movie =
        movie
        |> Ecto.Changeset.change(slug: "")
        |> Repo.update!()

      {:ok, _view, html} = live(conn, ~p"/movies/#{movie.id}")
      assert html =~ "Old movie page"
      assert html =~ ~p"/movies/#{movie.id}/legacy"
      assert html =~ movie.title
    end
  end

  describe "/movies-v2/:slug — alias" do
    test "still renders the V2 show page", %{conn: conn, movie: movie} do
      {:ok, _view, html} = live(conn, ~p"/movies-v2/#{movie.slug}")
      assert html =~ "Old movie page"
      assert html =~ ~p"/movies/#{movie.slug}/legacy"
      assert html =~ movie.title
    end
  end

  describe "/movies/:slug/legacy — V1 escape hatch" do
    test "renders the V1 show page", %{conn: conn, movie: movie} do
      {:ok, _view, html} = live(conn, ~p"/movies/#{movie.slug}/legacy")
      # V1 marker: the "Back to Movies" breadcrumb link uses ~p"/movies"
      assert html =~ "Back to Movies"
      assert html =~ movie.title
      # V2 marker should NOT appear on V1
      refute html =~ "Old movie page"
    end
  end
end

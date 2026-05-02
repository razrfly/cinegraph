defmodule CinegraphWeb.PersonLive.ShowV2RouteTest do
  use CinegraphWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Cinegraph.Movies.Person
  alias Cinegraph.Repo

  defp insert_person!(attrs) do
    defaults = %{
      tmdb_id: System.unique_integer([:positive]),
      name: "Person Show V2 Test #{System.unique_integer()}",
      known_for_department: "Acting"
    }

    %Person{}
    |> Person.changeset(Map.merge(defaults, attrs))
    |> Repo.insert!()
  end

  describe "/people/:slug — V2 primary" do
    test "renders the V2 show page", %{conn: conn} do
      person = insert_person!(%{name: "Canonical V2 Person"})

      {:ok, _view, html} = live(conn, ~p"/people/#{person.slug}")

      assert html =~ "← see classic page"
      assert html =~ ~p"/people/#{person.slug}/legacy"
      assert html =~ ~p"/people/#{person.slug}/movies"
      assert html =~ "Open all films"
      assert html =~ "Canonical V2 Person"
      assert html =~ ~s(<link rel="canonical" href="https://cinegraph.org/people/#{person.slug}")
      assert html =~ ~s(<meta property="og:type" content="profile")
      assert html =~ ~s(<meta property="og:title" content="Canonical V2 Person")
      assert html =~ ~s(<meta name="twitter:title" content="Canonical V2 Person")
      assert html =~ ~s("Person")
      assert html =~ ~s("BreadcrumbList")
    end

    test "role-filtered V2 show links to the matching scoped discovery page", %{conn: conn} do
      person = insert_person!(%{name: "Canonical V2 Director"})

      {:ok, _view, html} = live(conn, ~p"/people/#{person.slug}?role=director")

      assert html =~ ~p"/people/#{person.slug}/movies/directing"
      assert html =~ ~p"/people/#{person.slug}/movies"
      assert html =~ "Open directed films"
      assert html =~ "Open full filmography"
    end

    test "direct adult person routes still render", %{conn: conn} do
      person = insert_person!(%{name: "Direct Adult V2 Person", adult: true})

      {:ok, _view, html} = live(conn, ~p"/people/#{person.slug}")

      assert html =~ "Direct Adult V2 Person"
      assert html =~ "← see classic page"
    end

    test "legacy route renders the V1 show page", %{conn: conn} do
      person = insert_person!(%{name: "Canonical Legacy Person"})

      {:ok, _view, html} = live(conn, ~p"/people/#{person.slug}/legacy")

      assert html =~ "Back to People"
      assert html =~ "Canonical Legacy Person"
      refute html =~ "← see classic page"
    end
  end
end

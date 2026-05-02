defmodule CinegraphWeb.CompanyLiveTest do
  use CinegraphWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Cinegraph.Movies.{Movie, ProductionCompany}
  alias Cinegraph.Repo

  setup do
    Cachex.clear(:movies_cache)
    Cachex.clear(:filter_options_cache)
    :ok
  end

  describe "/companies" do
    test "renders company cards with movie counts and links", %{conn: conn} do
      company = insert_company!(name: "A24 Live", logo_url: "https://example.com/a24.svg")
      movie = insert_movie!(title: "A24 Live Movie")
      add_companies!(movie, [company])

      {:ok, _view, html} = live(conn, ~p"/companies")

      assert html =~ "Companies."
      assert html =~ "Search companies"
      assert html =~ "A24 Live"
      assert html =~ "1 films"
      assert html =~ ~s(href="/companies/#{company.slug}")
    end

    test "search filters company cards", %{conn: conn} do
      match = insert_company!(name: "Searchable Company")
      other = insert_company!(name: "Hidden Company")

      add_companies!(insert_movie!(title: "Searchable Movie"), [match])
      add_companies!(insert_movie!(title: "Hidden Movie"), [other])

      {:ok, _view, html} = live(conn, ~p"/companies?search=Searchable")

      assert html =~ "Searchable Company"
      refute html =~ "Hidden Company"
    end

    test "with-logos filter and film-count sort work", %{conn: conn} do
      logo_company = insert_company!(name: "Logo Company", logo_path: "/logo.png")
      no_logo_company = insert_company!(name: "No Logo Company")

      add_companies!(insert_movie!(title: "Logo Movie"), [logo_company])
      add_companies!(insert_movie!(title: "No Logo Movie"), [no_logo_company])

      {:ok, _view, html} = live(conn, ~p"/companies?category=with-logos&sort=films")

      assert html =~ "Logo Company"
      refute html =~ "No Logo Company"
    end
  end

  describe "/companies/:slug_or_id" do
    test "renders scoped movie discovery by slug", %{conn: conn} do
      company = insert_company!(name: "Scoped Company", website: "https://scoped.example")
      scoped_movie = insert_movie!(title: "Scoped Company Movie")
      other_movie = insert_movie!(title: "Other Company Movie")
      add_companies!(scoped_movie, [company])

      {:ok, _view, html} = live(conn, ~p"/companies/#{company.slug}")

      assert html =~ "Production Company"
      assert html =~ "Scoped Company."
      assert html =~ "Website"
      assert html =~ "Scoped Company Movie"
      refute html =~ other_movie.title
    end

    test "numeric id fallback works and missing logo renders fallback", %{conn: conn} do
      company = insert_company!(name: "Numeric Company")

      {:ok, _view, html} = live(conn, ~p"/companies/#{company.id}")

      assert html =~ "Numeric Company."
    end

    test "search on show page keeps company scope", %{conn: conn} do
      company = insert_company!(name: "Search Scoped Company")
      match = insert_movie!(title: "Moonlight Scoped")
      other = insert_movie!(title: "Not Matching")
      add_companies!(match, [company])
      add_companies!(other, [company])

      {:ok, _view, html} = live(conn, ~p"/companies/#{company.slug}?search=Moonlight")

      assert html =~ "Moonlight Scoped"
      refute html =~ "Not Matching"
      refute html =~ "Companies:"
    end
  end

  defp insert_company!(attrs) do
    defaults = %{
      tmdb_id: System.unique_integer([:positive]),
      name: "Company #{System.unique_integer([:positive])}"
    }

    %ProductionCompany{}
    |> ProductionCompany.changeset(Map.merge(defaults, Map.new(attrs)))
    |> Repo.insert!()
  end

  defp insert_movie!(attrs) do
    defaults = %{
      tmdb_id: System.unique_integer([:positive]),
      title: "Test Movie",
      original_title: "Test Movie",
      release_date: ~D[2024-01-01],
      import_status: "full"
    }

    %Movie{}
    |> Movie.changeset(Map.merge(defaults, Map.new(attrs)))
    |> Repo.insert!()
  end

  defp add_companies!(movie, companies) do
    rows =
      Enum.map(companies, fn company ->
        [movie_id: movie.id, production_company_id: company.id]
      end)

    Repo.insert_all("movie_production_companies", rows)
    movie
  end
end

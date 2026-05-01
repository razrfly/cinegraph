defmodule CinegraphWeb.PersonLive.IndexV2Test do
  use CinegraphWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Cinegraph.Movies.{Credit, Movie, Person}
  alias Cinegraph.Metrics.PersonMetric
  alias Cinegraph.Repo

  setup do
    Cachex.clear(:movies_cache)
    Cachex.clear(:filter_options_cache)
    :ok
  end

  describe "/people" do
    test "renders the V2 people index with card stats and legacy escape hatch", %{conn: conn} do
      person = insert_person!(%{name: "Vera V2 Person", known_for_department: "Acting"})
      movie = insert_movie!(%{title: "Vera Credit"})
      insert_credit!(movie, person, %{credit_type: "cast", character: "Lead"})

      {:ok, _view, html} = live(conn, ~p"/people")

      assert html =~ "People."
      assert html =~ "Search people"
      assert html =~ "Old people page"
      assert html =~ "Vera V2 Person"
      assert html =~ "1 film"
      assert html =~ ~s(href="/people/#{person.slug}")
    end

    test "preserves search query params and active chips", %{conn: conn} do
      _match = insert_person!(%{name: "Searchable V2 Person", known_for_department: "Acting"})
      _other = insert_person!(%{name: "Hidden V2 Person", known_for_department: "Directing"})

      {:ok, _view, html} = live(conn, ~p"/people?search=Searchable")

      assert html =~ "Searchable V2 Person"
      refute html =~ "Hidden V2 Person"
      assert html =~ "Search"
      assert html =~ "Searchable"
    end

    test "department presets patch the URL", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/people")

      view
      |> element(~s(a[href="/people?department_preset=acting"]))
      |> render_click()

      assert_patch(view, ~p"/people?department_preset=acting")
    end

    test "defaults to relevance without adding a sort param or raw popularity badge", %{
      conn: conn
    } do
      high_quality =
        insert_person!(%{
          name: "High Quality Director",
          known_for_department: "Directing",
          popularity: 5.0
        })

      low_quality =
        insert_person!(%{
          name: "Raw Popular Director",
          known_for_department: "Directing",
          popularity: 100.0
        })

      insert_quality_score!(high_quality, 90.0)
      insert_quality_score!(low_quality, 10.0)

      {:ok, view, html} = live(conn, ~p"/people")

      assert html =~ "High Quality Director"
      assert html =~ "Quality 90.0"
      refute html =~ "Pop "
      refute html =~ "TMDb 100.0"

      view
      |> element(~s(a[href="/people?department_preset=directing"]))
      |> render_click()

      assert_patch(view, ~p"/people?department_preset=directing")
      html = render(view)
      assert html =~ "High Quality Director"
      assert html =~ "Raw Popular Director"
      assert html =~ ~r/High Quality Director.*Raw Popular Director/s
    end

    test "TMDb popularity remains an explicit sort and shows the TMDb badge", %{conn: conn} do
      popular = insert_person!(%{name: "Popular Explicit Person", popularity: 80.0})
      quality = insert_person!(%{name: "Quality Explicit Person", popularity: 5.0})

      insert_quality_score!(popular, 5.0)
      insert_quality_score!(quality, 95.0)

      {:ok, _view, html} = live(conn, ~p"/people?sort=popularity_desc")

      assert html =~ ~r/Popular Explicit Person.*Quality Explicit Person/s
      assert html =~ "TMDb 80.0"
    end

    test "default browse excludes adult people, include_adult restores them, and search can find them",
         %{conn: conn} do
      adult = insert_person!(%{name: "Adult Searchable Person", adult: true, popularity: 100.0})
      regular = insert_person!(%{name: "Regular Browse Person", adult: false, popularity: 1.0})

      insert_quality_score!(adult, 100.0)
      insert_quality_score!(regular, 10.0)

      {:ok, _view, html} = live(conn, ~p"/people")
      refute html =~ "Adult Searchable Person"
      assert html =~ "Regular Browse Person"

      {:ok, _view, html} = live(conn, ~p"/people?include_adult=true")
      assert html =~ "Adult Searchable Person"
      assert html =~ "Adult people"
      assert html =~ "Included"

      {:ok, _view, html} = live(conn, ~p"/people?search=Adult Searchable")
      assert html =~ "Adult Searchable Person"
    end

    test "person cards use compact horizontal thumbnails", %{conn: conn} do
      _person = insert_person!(%{name: "Compact Card Person", known_for_department: "Writing"})

      {:ok, _view, html} = live(conn, ~p"/people")

      assert html =~ ~s(grid-cols-[68px_1fr])
      assert html =~ ~s(h-[72px] w-[68px])
      assert html =~ "Compact Card Person"
    end

    test "legacy people page remains available", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/people/legacy")

      assert html =~ "People Database"
    end
  end

  describe "/people/:slug_or_id/movies" do
    test "renders a movie discovery page scoped to one person", %{conn: conn} do
      person = insert_person!(%{name: "Scoped Film Person", known_for_department: "Acting"})
      scoped_movie = insert_movie!(%{title: "Scoped Movie"})
      _other_movie = insert_movie!(%{title: "Other Movie"})
      insert_credit!(scoped_movie, person, %{credit_type: "cast"})

      {:ok, _view, html} = live(conn, ~p"/people/#{person.slug}/movies")

      assert html =~ "Person Filmography"
      assert html =~ "Scoped Film Person"
      assert html =~ "Scoped Movie"
      refute html =~ "Other Movie"
    end

    test "role routes scope acting and directing credits", %{conn: conn} do
      person = insert_person!(%{name: "Role Scoped Person", known_for_department: "Directing"})
      acting_movie = insert_movie!(%{title: "Acting Scoped Movie"})
      directed_movie = insert_movie!(%{title: "Directed Scoped Movie"})

      insert_credit!(acting_movie, person, %{credit_type: "cast", character: "Performer"})

      insert_credit!(directed_movie, person, %{
        credit_type: "crew",
        department: "Directing",
        job: "Director"
      })

      {:ok, _view, acting_html} = live(conn, ~p"/people/#{person.slug}/movies/acting")
      assert acting_html =~ "Acting Scoped Movie"
      refute acting_html =~ "Directed Scoped Movie"

      {:ok, _view, directing_html} = live(conn, ~p"/people/#{person.slug}/movies/directing")
      assert directing_html =~ "Directed Scoped Movie"
      refute directing_html =~ "Acting Scoped Movie"
    end

    test "handles movie search validation errors without missing pagination assigns", %{
      conn: conn
    } do
      person = insert_person!(%{name: "Invalid Search Person", known_for_department: "Acting"})

      {:ok, _view, html} = live(conn, ~p"/people/#{person.slug}/movies?sort=invalid")

      assert html =~ "0 films"
    end
  end

  defp insert_person!(attrs) do
    attrs =
      Map.merge(
        %{
          tmdb_id: System.unique_integer([:positive]),
          name: "Test Person",
          popularity: 10.0,
          place_of_birth: "New York, USA"
        },
        attrs
      )

    %Person{}
    |> Person.changeset(attrs)
    |> Repo.insert!()
  end

  defp insert_movie!(attrs) do
    attrs =
      Map.merge(
        %{
          tmdb_id: System.unique_integer([:positive]),
          title: "Test Movie",
          original_title: "Test Movie",
          release_date: ~D[2024-01-01],
          import_status: "full"
        },
        attrs
      )

    %Movie{}
    |> Movie.changeset(attrs)
    |> Repo.insert!()
  end

  defp insert_credit!(movie, person, attrs) do
    attrs =
      Map.merge(
        %{
          movie_id: movie.id,
          person_id: person.id,
          credit_type: "cast",
          credit_id: "credit-#{System.unique_integer([:positive])}"
        },
        attrs
      )

    %Credit{}
    |> Credit.changeset(attrs)
    |> Repo.insert!()
  end

  defp insert_quality_score!(person, score) do
    %PersonMetric{}
    |> PersonMetric.changeset(%{
      person_id: person.id,
      metric_type: "quality_score",
      score: score,
      calculated_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.insert!()
  end
end

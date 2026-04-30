defmodule CinegraphWeb.GlobalSearchLiveTest do
  use CinegraphWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Cinegraph.Movies.{Movie, Person}

  defp insert_movie!(attrs) do
    defaults = %{
      tmdb_id: System.unique_integer([:positive]),
      title: "Test Movie",
      original_title: "Test Movie",
      release_date: ~D[2024-01-01]
    }

    %Movie{}
    |> Movie.changeset(Map.merge(defaults, attrs))
    |> Cinegraph.Repo.insert!()
  end

  defp insert_person!(attrs) do
    defaults = %{
      tmdb_id: System.unique_integer([:positive]),
      name: "Test Person",
      popularity: 5.0,
      known_for_department: "Acting"
    }

    %Person{}
    |> Person.changeset(Map.merge(defaults, attrs))
    |> Cinegraph.Repo.insert!()
  end

  setup do
    Cachex.clear(:movies_cache)
    :ok
  end

  describe "mount/3" do
    test "renders the input and no dropdown by default", %{conn: conn} do
      {:ok, _view, html} = live_isolated(conn, CinegraphWeb.GlobalSearchLive)

      assert html =~ "Search films, people, lists, companies"
      assert html =~ ~s|id="global-search-input"|
      refute html =~ ~s|id="global-search-listbox"|
    end

    test "renders the GlobalSearch hook attribute", %{conn: conn} do
      {:ok, _view, html} = live_isolated(conn, CinegraphWeb.GlobalSearchLive)
      assert html =~ ~s|phx-hook="GlobalSearch"|
    end
  end

  describe "change event" do
    test "below the minimum query length leaves the dropdown closed", %{conn: conn} do
      {:ok, view, _} = live_isolated(conn, CinegraphWeb.GlobalSearchLive)

      html = render_change(view, "change", %{"q" => "a"})

      refute html =~ ~s|id="global-search-listbox"|
    end

    test "single multibyte character leaves the dropdown closed", %{conn: conn} do
      {:ok, view, _} = live_isolated(conn, CinegraphWeb.GlobalSearchLive)

      html = render_change(view, "change", %{"q" => "é"})

      refute html =~ ~s|id="global-search-listbox"|
    end

    test "whitespace-only query leaves the dropdown closed", %{conn: conn} do
      {:ok, view, _} = live_isolated(conn, CinegraphWeb.GlobalSearchLive)

      html = render_change(view, "change", %{"q" => "  "})

      refute html =~ ~s|id="global-search-listbox"|
    end

    test "a real query opens the dropdown and renders results", %{conn: conn} do
      _movie = insert_movie!(%{title: "Sondergaard Standard", tmdb_id: 80_001})
      _person = insert_person!(%{name: "Sondergaard Searchable", tmdb_id: 80_002})

      {:ok, view, _} = live_isolated(conn, CinegraphWeb.GlobalSearchLive)

      _ = render_change(view, "change", %{"q" => "sondergaard"})
      html = render_async(view)

      assert html =~ ~s|id="global-search-listbox"|
      assert html =~ "phx-mousedown-prevent"
      assert html =~ "Sondergaard Standard"
      assert html =~ "Sondergaard Searchable"
    end

    test "a query with no matches renders the empty state", %{conn: conn} do
      {:ok, view, _} = live_isolated(conn, CinegraphWeb.GlobalSearchLive)

      _ = render_change(view, "change", %{"q" => "zzzqqqxxx9999"})
      html = render_async(view)

      assert html =~ "No matches"
    end
  end

  describe "focus + recents" do
    test "focus event opens the dropdown when no query is entered", %{conn: conn} do
      {:ok, view, _} = live_isolated(conn, CinegraphWeb.GlobalSearchLive)

      # Without focus, the empty-query dropdown is hidden
      refute render(view) =~ ~s|id="global-search-listbox"|

      # Push a recent so the recents panel has something to show, then focus.
      _ =
        render_hook(view, "update_recents", %{
          "recents" => [%{"href" => "/movies/x", "label" => "Recent Film"}]
        })

      _ = render_hook(view, "focus", %{})
      html = render(view)

      assert html =~ ~s|id="global-search-listbox"|
      assert html =~ "Recent Film"
    end

    test "update_recents accepts a list and caps at 5", %{conn: conn} do
      {:ok, view, _} = live_isolated(conn, CinegraphWeb.GlobalSearchLive)

      recents =
        for n <- 1..10 do
          %{"href" => "/movies/x#{n}", "label" => "Recent #{n}"}
        end

      _ = render_hook(view, "update_recents", %{"recents" => recents})
      _ = render_hook(view, "focus", %{})
      html = render(view)

      assert html =~ "Recent 1"
      assert html =~ "Recent 5"
      refute html =~ "Recent 6"
    end

    test "recents sanitize unsafe hrefs", %{conn: conn} do
      {:ok, view, _} = live_isolated(conn, CinegraphWeb.GlobalSearchLive)

      _ =
        render_hook(view, "update_recents", %{
          "recents" => [%{"href" => "javascript:alert(1)", "label" => "Unsafe Recent"}]
        })

      _ = render_hook(view, "focus", %{})
      html = render(view)

      assert html =~ "Unsafe Recent"
      assert html =~ ~s|href="#"|
      refute html =~ "javascript:alert"
    end
  end

  describe "result row shape" do
    test "film rows link to /movies/<slug> with poster + director", %{conn: conn} do
      _movie = insert_movie!(%{title: "Linkable Film", tmdb_id: 80_010})

      {:ok, view, _} = live_isolated(conn, CinegraphWeb.GlobalSearchLive)
      _ = render_change(view, "change", %{"q" => "linkable film"})
      html = render_async(view)

      assert html =~ ~r|href="/movies/linkable-film[^"]*"|
    end

    test "person rows link to /people/<slug>", %{conn: conn} do
      _person = insert_person!(%{name: "Linkable Person", tmdb_id: 80_011, popularity: 50.0})

      {:ok, view, _} = live_isolated(conn, CinegraphWeb.GlobalSearchLive)
      _ = render_change(view, "change", %{"q" => "linkable person"})
      html = render_async(view)

      assert html =~ ~r|href="/people/linkable-person[^"]*"|
    end
  end
end

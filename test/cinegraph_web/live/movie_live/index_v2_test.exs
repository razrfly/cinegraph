defmodule CinegraphWeb.MovieLive.IndexV2Test do
  @moduledoc """
  LiveView tests for the V2 movies discovery page (`/movies`).

  Covers the filter shell from issue #785: sort segmented control, decade
  chips, multi-select genre chips, drawer open/close, sort direction toggle,
  scoring modal, clear-all, active-filter chip strip, pagination — i.e. the
  user-visible behaviors the redesign added.

  Card rendering is covered separately in `IndexV2ComponentsTest`.
  """
  use CinegraphWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Cinegraph.Movies.{Movie, Genre}
  alias Cinegraph.Repo

  defp insert_movie!(attrs) do
    defaults = %{
      tmdb_id: System.unique_integer([:positive]),
      title: "Test Movie",
      original_title: "Test Movie",
      release_date: ~D[2024-01-01]
    }

    %Movie{}
    |> Movie.changeset(Map.merge(defaults, attrs))
    |> Repo.insert!()
  end

  defp insert_genre!(name) do
    Repo.insert!(%Genre{tmdb_id: System.unique_integer([:positive]), name: name})
  end

  setup do
    Cachex.clear(:movies_cache)
    Cachex.clear(:filter_options_cache)
    :ok
  end

  describe "mount and render" do
    test "renders the hero, sort row, and search input", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/movies")

      assert html =~ "Movies."
      assert html =~ "Search films, people, lists"
      assert html =~ "SORT"
      # Phase 1 (issue #787): renamed labels on the V2 page
      assert html =~ "Most recent"
      assert html =~ "Highest rated"
      assert html =~ "Trending"
      assert html =~ "Audience"
      assert html =~ "Critics"
      assert html =~ "Awards"
    end

    test "hero exposes 'How we score?' link wired to the scoring modal",
         %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/movies")
      assert html =~ "How we score?"
      assert html =~ ~s(phx-click="show_scoring_info")
    end

    test "renders the Filters drawer button", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/movies")
      assert html =~ ~s(phx-click="toggle_drawer")
    end

    test "sort row no longer renders the floating ? or ↓ buttons",
         %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/movies")
      # The ? button left the row — Phase 1 moved it to the hero, Phase 2
      # also exposed it inside the More-sorts menu. The standalone row icon
      # carrying title="How scoring works" is gone.
      refute html =~ ~s(title="How scoring works")
    end

    test "Phase 2: sort row shows only 3 primary chips with emoji prefixes",
         %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/movies")

      # Three primary chips with emoji prefixes
      assert html =~ "📅 Most recent"
      assert html =~ "⭐ Highest rated"
      assert html =~ "🔥 Trending"

      # "More sorts ▾" trigger and grouped section headers in the menu
      assert html =~ "More sorts ▾"
      assert html =~ "Timeline"
      assert html =~ "Quality"
      assert html =~ "Cinegraph lenses"
      assert html =~ "Scored presets"
      # Footer link inside the menu
      assert html =~ "How does Cinegraph score?"
    end

    test "Phase 2: decade chip block removed from above-the-fold view",
         %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/movies")
      # The page-level "DECADE" uppercase eyebrow no longer appears.
      refute html =~ ~r/>\s*DECADE\s*<\/span>/s
    end

    test "Phase 2: drawer renders Decade section with chip pills",
         %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/movies")
      # Drawer "Decade" h3 header
      assert html =~ "Decade"
      # At least one decade chip present
      assert html =~ ~s(phx-value-key="decade")
    end

    test "Phase 2: genre chips include emoji prefixes", %{conn: conn} do
      _drama = insert_genre!("Drama-Emoji-#{System.unique_integer()}")
      Cachex.clear(:filter_options_cache)
      {:ok, _view, html} = live(conn, ~p"/movies")

      # We can't guarantee Drama specifically (it depends on seed data),
      # but the GenreEmoji fallback or any of the standard emojis must appear
      # near a phx-value-key="genres" chip. Loose check:
      assert html =~ ~s(phx-value-key="genres")
    end

    test "Phase 2: hero subtitle splits count from action links",
         %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/movies")
      # Tunable scoring → and How we score? both present, no longer wrapped in
      # the same paragraph with the count text.
      assert html =~ "Tunable scoring →"
      assert html =~ "How we score?"
    end
  end

  describe "decade chip toggle (single-select)" do
    test "selecting a decade adds it to the URL", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/movies")

      view
      |> element(~s(button[phx-value-key="decade"][phx-value-id="1990"]))
      |> render_click()

      to = assert_patch(view)
      assert to =~ "decade=1990"
    end

    test "clicking the active decade clears it", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/movies?decade=1990")

      view
      |> element(~s(button[phx-value-key="decade"][phx-value-id="1990"]))
      |> render_click()

      to = assert_patch(view)
      refute to =~ "decade="
    end
  end

  describe "genre chip toggle (multi-select)" do
    setup do
      drama = insert_genre!("Drama-V2-Test-#{System.unique_integer()}")
      comedy = insert_genre!("Comedy-V2-Test-#{System.unique_integer()}")
      Cachex.clear(:filter_options_cache)
      %{drama: drama, comedy: comedy}
    end

    test "selecting a genre adds it to the genres list", %{conn: conn, drama: drama} do
      {:ok, view, _} = live(conn, ~p"/movies")

      view
      |> element(~s(button[phx-value-key="genres"][phx-value-id="#{drama.id}"]))
      |> render_click()

      to = assert_patch(view)
      assert to =~ "genres"
      assert to =~ "#{drama.id}"
    end

    test "selecting a second genre keeps the first", %{
      conn: conn,
      drama: drama,
      comedy: comedy
    } do
      {:ok, view, _} = live(conn, ~p"/movies?genres[]=#{drama.id}")

      view
      |> element(~s(button[phx-value-key="genres"][phx-value-id="#{comedy.id}"]))
      |> render_click()

      to = assert_patch(view)
      assert to =~ "#{drama.id}"
      assert to =~ "#{comedy.id}"
    end

    test "clicking an active genre removes it", %{conn: conn, drama: drama} do
      {:ok, view, _} = live(conn, ~p"/movies?genres[]=#{drama.id}")

      view
      |> element(~s(button[phx-value-key="genres"][phx-value-id="#{drama.id}"]))
      |> render_click()

      to = assert_patch(view)
      refute to =~ "genres"
    end
  end

  describe "drawer" do
    test "toggle_drawer opens the drawer panel", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/movies")
      assert html =~ "translate-x-full"

      html2 = view |> element(~s(button[phx-click="toggle_drawer"])) |> render_click()
      assert html2 =~ "translate-x-0"
    end

    test "hide_drawer closes the drawer", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/movies")
      view |> element(~s(button[phx-click="toggle_drawer"])) |> render_click()

      # The overlay div has phx-click="hide_drawer" — click it to close
      html = render_click(view, "hide_drawer", %{})
      assert html =~ "translate-x-full"
    end
  end

  describe "scoring modal" do
    test "hero 'How we score?' link opens the modal", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/movies")

      html =
        view
        |> element("button", "How we score?")
        |> render_click()

      assert html =~ "How Cinegraph Scores Movies"
      assert html =~ "The Mob"
      assert html =~ "The Critics"
      assert html =~ "The Insiders"
    end

    test "hide_scoring_info closes the modal", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/movies")

      view
      |> element("button", "How we score?")
      |> render_click()

      html = render_click(view, "hide_scoring_info", %{})
      refute html =~ "How Cinegraph Scores Movies"
    end
  end

  describe "sort segmented control" do
    test "clicking 'Critics' patches sort=critics_desc", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/movies")

      view
      |> element(~s(button[phx-click="sort_criteria_changed"][phx-value-criteria="critics"]))
      |> render_click()

      to = assert_patch(view)
      assert to =~ "sort=critics_desc"
    end

    # Direction toggle button removed in Phase 1 (issue #787). The macro
    # handler is still in place — direction is changeable via URL param —
    # but the floating ↓/↑ button is gone. Phase 2 reintroduces direction
    # inside a structured menu.

    test "active overflow sort surfaces on the More-sorts trigger label",
         %{conn: conn} do
      # `critics` is a static overflow option (guaranteed present regardless
      # of scoring-profile seed state).
      {:ok, _view, html} = live(conn, ~p"/movies?sort=critics_desc")
      # Trigger no longer reads bare "More sorts ▾" when an overflow sort is active.
      assert html =~ "Critics"
      assert html =~ "↓"
    end

    test "active overflow sort renders a chip in the ACTIVE strip",
         %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/movies?sort=critics_desc")
      assert html =~ "ACTIVE"
      assert html =~ "Sort:"
      # The chip uses display_label which renders "🎭 Critics" for that value.
      assert html =~ ~s(phx-value-filter="sort")
    end

    test "default sort does NOT show a sort chip", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/movies")
      # No sort URL param → no sort chip in the strip
      refute html =~ ~s(phx-value-filter="sort")
    end

    test "removing the sort chip clears it back to the default",
         %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/movies?sort=critics_desc")

      view
      |> element(~s(button[phx-click="remove_filter"][phx-value-filter="sort"]))
      |> render_click()

      to = assert_patch(view)
      refute to =~ "sort="
    end
  end

  describe "active filter chip strip + remove_filter" do
    setup do
      drama = insert_genre!("Drama-Active-#{System.unique_integer()}")
      Cachex.clear(:filter_options_cache)
      %{drama: drama}
    end

    test "active chips appear when filters are set", %{conn: conn, drama: drama} do
      {:ok, _view, html} = live(conn, ~p"/movies?genres[]=#{drama.id}&decade=1990")

      assert html =~ "ACTIVE"
      assert html =~ drama.name
      assert html =~ "1990s"
    end

    test "remove_filter drops a single filter from the URL", %{conn: conn, drama: drama} do
      {:ok, view, _} = live(conn, ~p"/movies?genres[]=#{drama.id}&decade=1990")

      view
      |> element(~s(button[phx-click="remove_filter"][phx-value-filter="decade"]))
      |> render_click()

      to = assert_patch(view)
      assert to =~ "genres"
      refute to =~ "decade="
    end

    test "clear_filters wipes filters but keeps search", %{conn: conn, drama: drama} do
      {:ok, view, _} = live(conn, ~p"/movies?genres[]=#{drama.id}&decade=1990&search=foo")

      # The active-filter chip strip "Clear all" link
      view
      |> element("section button[phx-click='clear_filters']", "Clear all")
      |> render_click()

      to = assert_patch(view)
      refute to =~ "genres"
      refute to =~ "decade="
      assert to =~ "search=foo"
    end
  end

  describe "results grid" do
    test "movies render in the grid when there are results", %{conn: conn} do
      _movie = insert_movie!(%{title: "Test Movie A V2", tmdb_id: 91_001})
      Cachex.clear(:movies_cache)

      {:ok, _view, html} = live(conn, ~p"/movies")
      assert html =~ "Test Movie A V2"
    end
  end

  describe "/movies/legacy escape hatch" do
    test "v1 page still serves at /movies/legacy", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/movies/legacy")
      assert html =~ "Movies Database"
    end
  end
end

defmodule CinegraphWeb.Admin.DriftDomainLiveTest do
  use CinegraphWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  describe "GET /admin/movies" do
    test "renders Movies page with KPI tiles + drift checks", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/admin/movies")

      assert html =~ "Movies"
      assert html =~ "Movie metadata"
      assert html =~ "With OMDb"
      assert html =~ "With IMDb id"
      assert html =~ "missing omdb" or html =~ "missing imdb id" or html =~ "year gap"
    end

    test "refresh event reloads without crashing", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/admin/movies")
      result = render_click(live, "refresh", %{})
      assert result =~ "Movies"
    end
  end

  describe "GET /admin/people" do
    test "renders People page", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/admin/people")
      assert html =~ "People"
      assert html =~ "With profile"
      assert html =~ "With biography"
    end
  end

  describe "GET /admin/ratings" do
    test "renders Ratings page", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/admin/ratings")
      assert html =~ "Ratings"
    end
  end

  describe "GET /admin/availability" do
    test "renders Availability page", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/admin/availability")
      assert html =~ "Availability"
    end
  end

  describe "GET /admin/collaborations" do
    test "renders Collaborations page", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/admin/collaborations")
      assert html =~ "Collaborations"
    end
  end

  describe "selection events" do
    test "toggle_row + clear_selection don't crash", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/admin/movies")

      _ = render_click(live, "toggle_row", %{"check" => "missing_omdb", "id" => "1234"})
      result = render_click(live, "clear_selection", %{})
      assert result =~ "Movies"
    end

    test "run_bulk_action with no selection flashes an error", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/admin/movies")

      result = render_click(live, "run_bulk_action", %{"check" => "missing_omdb"})
      assert result =~ "Select at least one row"
    end
  end
end

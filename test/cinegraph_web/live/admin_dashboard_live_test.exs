defmodule CinegraphWeb.AdminDashboardLiveTest do
  use CinegraphWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  describe "GET /admin" do
    test "renders the 5 KPI tiles", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/admin")

      assert html =~ "Cinegraph admin"
      # KPI tile titles
      assert html =~ "Verdict"
      assert html =~ "Queue depth"
      assert html =~ "Today"
      assert html =~ "Coverage"
      assert html =~ "Alerts"
    end

    test "renders the nav grid sections", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/admin")

      assert html =~ "Observability"
      assert html =~ "Data"
      assert html =~ "Quality"
      # Phase 1 routes are in the grid
      assert html =~ "Queues"
      assert html =~ "Jobs"
      assert html =~ "Scheduled"
    end

    test "refresh event reloads data without crashing", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/admin")

      result = render_click(live, "refresh", %{})
      assert result =~ "Cinegraph admin"
    end
  end
end

defmodule CinegraphWeb.AdminHealthLive.ShowTest do
  use CinegraphWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  describe "GET /admin/health" do
    test "renders the hero band, today's activity, and is reachable", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/admin/health")

      assert html =~ "Cinegraph Health"
      assert html =~ "Today"
      assert html =~ "Movies+"
      assert html =~ "Refresh now"
    end

    test "manual refresh button triggers a reload", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/admin/health")

      # The button doesn't change visible content much; we just assert the
      # event is handled without crashing the LiveView.
      assert render_click(live, "refresh") =~ "Cinegraph Health"
    end

    test "renders People domain card with top-3 signals", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/admin/health")

      # The People card always shows up under the Domain drift section
      assert html =~ "People"
      assert html =~ "View details"
    end

    test "open_drawer event mounts the drawer for People", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/admin/health")

      html = render_click(live, "open_drawer", %{"domain" => "people"})

      assert html =~ "People drift"
      # Drawer dialog role (renders fixed-positioned aside)
      assert html =~ ~s(role="dialog")
    end

    test "close_drawer event removes the drawer", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/admin/health")

      _opened = render_click(live, "open_drawer", %{"domain" => "people"})
      closed = render_click(live, "close_drawer", %{})

      refute closed =~ ~s(role="dialog")
    end

    test "open_drawer with unknown domain is a no-op (does not crash)", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/admin/health")
      html = render_click(live, "open_drawer", %{"domain" => "bogus"})
      refute html =~ ~s(role="dialog")
    end

    test "renders all 4 domain cards (people, movies, festivals, ratings)", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/admin/health")

      assert html =~ ~s(phx-value-domain="people")
      assert html =~ ~s(phx-value-domain="movies")
      assert html =~ ~s(phx-value-domain="festivals")
      assert html =~ ~s(phx-value-domain="ratings")
    end

    test "movies drawer shows year-imports drill-down link", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/admin/health")
      html = render_click(live, "open_drawer", %{"domain" => "movies"})

      assert html =~ "Movies drift"
      assert html =~ "/admin/year-imports"
    end

    test "festivals drawer shows award-imports drill-down link", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/admin/health")
      html = render_click(live, "open_drawer", %{"domain" => "festivals"})

      assert html =~ "Festivals drift"
      assert html =~ "/admin/award-imports"
    end
  end
end

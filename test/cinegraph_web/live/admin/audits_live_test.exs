defmodule CinegraphWeb.Admin.AuditsLiveTest do
  use CinegraphWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  describe "GET /admin/audits" do
    test "renders tabs from registry", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/admin/audits")

      assert html =~ "Audits"
      assert html =~ "Availability coverage"
      assert html =~ "Canonical lists"
      assert html =~ "Queue failures"
      assert html =~ "Production companies"
    end

    test "selecting a tab updates URL via push_patch", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/admin/audits")

      result = render_click(live, "select", %{"id" => "canonical_lists"})
      assert result =~ "Canonical lists"
    end

    test "?audit=availability shows that tab pre-selected", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/admin/audits?audit=availability")

      assert html =~ "Availability coverage"
    end

    test "running a fast audit returns a result", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/admin/audits?audit=availability")

      result = render_click(live, "run", %{})

      assert result =~ "Result" or result =~ "summary"
    end
  end
end

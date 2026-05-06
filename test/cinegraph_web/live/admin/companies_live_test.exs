defmodule CinegraphWeb.Admin.CompaniesLiveTest do
  use CinegraphWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  describe "GET /admin/companies" do
    test "renders KPI strip + filter pills + table", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/admin/companies")

      assert html =~ "Production companies"
      assert html =~ "Total"
      assert html =~ "With logo"
      assert html =~ "With slug"
      assert html =~ "With TMDb metadata"
      assert html =~ "Missing logo"
      assert html =~ "Missing slug"
      assert html =~ "Missing metadata"
    end

    test "filter URL param activates the filter pill", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/admin/companies?missing=logo")

      # Active filter renders with bg-blue-600 class
      assert html =~ "bg-blue-600 text-white"
    end

    test "refresh event reloads without crashing", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/admin/companies")

      result = render_click(live, "refresh", %{})
      assert result =~ "Production companies"
    end
  end
end

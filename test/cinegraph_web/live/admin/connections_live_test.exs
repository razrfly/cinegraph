defmodule CinegraphWeb.Admin.ConnectionsLiveTest do
  use CinegraphWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  test "renders the connection-health page with backend counts", %{conn: conn} do
    {:ok, _live, html} = live(conn, ~p"/admin/connections")

    assert html =~ "Database connections"
    assert html =~ "backends"
    # The test database appears in the by-database table.
    assert html =~ "By database"
    # A status badge is rendered (OK/WARN/CRIT).
    assert html =~ ~r/OK|WARN|CRIT/
  end
end

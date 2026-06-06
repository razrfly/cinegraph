defmodule CinegraphWeb.RedirectControllerTest do
  use CinegraphWeb.ConnCase, async: true

  test "GET /movies/discover permanently redirects to /algorithms", %{conn: conn} do
    conn = get(conn, ~p"/movies/discover")
    assert redirected_to(conn, 301) == ~p"/algorithms"
  end
end

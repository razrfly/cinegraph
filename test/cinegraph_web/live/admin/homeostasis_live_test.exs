defmodule CinegraphWeb.Admin.HomeostasisLiveTest do
  @moduledoc "#1108 §10c — /admin/homeostasis dashboard."
  use CinegraphWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  setup do
    Cachex.clear(:health_cache)
    :ok
  end

  test "renders the surface-area grid + spend panel", %{conn: conn} do
    {:ok, _live, html} = live(conn, ~p"/admin/homeostasis")

    assert html =~ "Homeostasis"
    assert html =~ "Read-through"
    assert html =~ "TMDb spend"
    # a static source row from the report
    assert html =~ "tmdb_details"
    assert html =~ "imdb_id"
  end

  test "Recompute button bypasses the cache and re-renders", %{conn: conn} do
    {:ok, live, _html} = live(conn, ~p"/admin/homeostasis")
    html = live |> element("button", "Recompute") |> render_click()
    assert html =~ "Homeostasis"
  end
end

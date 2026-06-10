defmodule CinegraphWeb.HomeLiveTest do
  use CinegraphWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  setup do
    Cachex.clear(:movies_cache)
    Cachex.clear(:health_cache)
    :ok
  end

  test "GET / renders the v2 dynamic home page", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")

    assert html =~ "Cinegraph"
    assert html =~ "What&#39;s worth watching tonight?"
    assert html =~ "The video store clerk for the streaming era"
    assert html =~ "Today&#39;s spotlight"
    assert html =~ "Critics and audiences don&#39;t always agree"
    assert html =~ "Cinegraph lets you"
    assert html =~ "Ask the Video Clerk"
    assert html =~ ~s(href="/six-degrees")

    # Video Clerk shelved behind admin auth (#1098) — homepage CTA now points public to /now-playing.
    assert html =~ ~s(href="/now-playing")
  end
end

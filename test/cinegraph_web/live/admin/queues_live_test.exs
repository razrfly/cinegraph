defmodule CinegraphWeb.Admin.QueuesLiveTest do
  use CinegraphWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  describe "GET /admin/queues" do
    test "renders queue snapshot with all configured queues", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/admin/queues")

      assert html =~ "Queues"
      assert html =~ "Per queue"
      # Each queue shows its name in <code>
      assert html =~ "tmdb"
      assert html =~ "omdb"
      assert html =~ "metrics"
      assert html =~ "maintenance"
    end

    test "shows side widgets for PQS and festival monitor", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/admin/queues")

      assert html =~ "PQS health"
      assert html =~ "Festival inference monitor"
    end

    test "refresh event reloads data", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/admin/queues")

      result = render_click(live, "refresh", %{})
      assert result =~ "Available jobs"
    end
  end
end

defmodule CinegraphWeb.Admin.JobsLiveTest do
  use CinegraphWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  describe "GET /admin/jobs" do
    test "renders KPI strip and per-worker table at default 24h range", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/admin/jobs")

      assert html =~ "Jobs"
      assert html =~ "Completed (24h)"
      assert html =~ "Failed (24h)"
      assert html =~ "Success rate"
      assert html =~ "Per-worker breakdown"
    end

    test "range param updates the KPI labels", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/admin/jobs?range=1h")

      assert html =~ "Completed (1h)"
      refute html =~ "Completed (24h)"
    end

    test "unknown range falls back to 24h", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/admin/jobs?range=bogus")

      assert html =~ "Completed (24h)"
    end

    test "lists at least one registered worker row", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/admin/jobs")

      # Worker labels from JobRegistry should appear in the table
      assert html =~ "Biography refresh sweeper"
    end
  end
end

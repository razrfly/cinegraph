defmodule CinegraphWeb.Admin.ScheduledLiveTest do
  use CinegraphWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  describe "GET /admin/scheduled" do
    test "renders the scheduled jobs table with all 24 cron entries", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/admin/scheduled")

      # Page header + subtitle reference all 24 entries
      assert html =~ "Scheduled jobs"
      assert html =~ "24 cron entries"

      # A representative entry from each section
      assert html =~ "Biography refresh sweeper"
      assert html =~ "OMDb backfill sweeper"
      assert html =~ "Festival sync sweeper"
      assert html =~ "PQS — daily incremental"
      assert html =~ "Movies cache warmer"

      # Each entry exposes its cron + queue + run-now button
      assert html =~ "*/4 * * * *"
      assert html =~ "Run now"
    end

    test "filter narrows the visible rows", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/admin/scheduled")

      filtered = render_change(live, "filter", %{"q" => "PQS"})

      assert filtered =~ "PQS — daily incremental"
      refute filtered =~ "Biography refresh sweeper"
    end

    test "clear_filter restores all entries", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/admin/scheduled")

      _ = render_change(live, "filter", %{"q" => "no-such-job-xyzzy"})

      restored = render_click(live, "clear_filter", %{})
      assert restored =~ "Biography refresh sweeper"
    end

    test "toggle_args reveals the args column", %{conn: conn} do
      {:ok, live, html} = live(conn, ~p"/admin/scheduled")

      # PQS args are not visible by default
      refute html =~ ~s("daily_incremental")

      after_toggle = render_click(live, "toggle_args", %{})
      assert after_toggle =~ "daily_incremental"
    end

    test "trigger event with unknown id flashes an error", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/admin/scheduled")

      result = render_click(live, "trigger", %{"id" => "no_such_id_anywhere"})
      assert result =~ "Unknown job id"
    end
  end

  describe "GET /admin/scheduled/:id" do
    test "drilldown for a known id renders entry metadata", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/admin/scheduled/biography_refresh_sweeper")

      assert html =~ "Biography refresh sweeper"
      assert html =~ "30 5 * * *"
      assert html =~ "tmdb"
      assert html =~ "people"
      assert html =~ "Run now"
    end

    test "drilldown for unknown id redirects to index with flash", %{conn: conn} do
      {:error, {:live_redirect, %{to: "/admin/scheduled", flash: flash}}} =
        live(conn, ~p"/admin/scheduled/totally-unknown-id-xyz")

      assert flash["error"] =~ "totally-unknown-id-xyz"
    end
  end
end

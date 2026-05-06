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

      # The admin layout's mobile menu also uses role="dialog", so use the
      # drift drawer's unique close-button aria-label as the discriminator.
      refute closed =~ ~s(aria-label="Close drawer")
    end

    test "open_drawer with unknown domain is a no-op (does not crash)", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/admin/health")
      html = render_click(live, "open_drawer", %{"domain" => "bogus"})
      refute html =~ ~s(aria-label="Close drawer")
    end

    test "renders all 5 domain cards including collaborations", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/admin/health")

      assert html =~ ~s(phx-value-domain="people")
      assert html =~ ~s(phx-value-domain="movies")
      assert html =~ ~s(phx-value-domain="festivals")
      assert html =~ ~s(phx-value-domain="ratings")
      assert html =~ ~s(phx-value-domain="collaborations")
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

    test "open_drawer event mounts the drawer for Collaborations", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/admin/health")
      html = render_click(live, "open_drawer", %{"domain" => "collaborations"})

      assert html =~ "Collaborations drift"
      assert html =~ ~s(role="dialog")
    end
  end

  describe "domain_card_props/2" do
    alias CinegraphWeb.AdminHealthLive.Show

    test "headline says 'unavailable' when source check has blocked_reason" do
      verdict = %{
        domains: %{
          movies: %{
            status: :red,
            checks: [
              %{
                check: :year_gap,
                status: :unknown,
                total_population: 0,
                affected_count: 0,
                affected_pct: 0.0,
                blocked_reason: "no cached export"
              },
              %{
                check: :missing_omdb,
                status: :red,
                total_population: 100,
                affected_count: 80,
                affected_pct: 80.0,
                blocked_reason: nil
              }
            ]
          }
        }
      }

      props = Show.domain_card_props(verdict, :movies)
      assert props.headline =~ "unavailable"
      assert props.unknown_count == 1
    end

    test "headline computes normally when source check is healthy" do
      verdict = %{
        domains: %{
          movies: %{
            status: :green,
            checks: [
              %{
                check: :year_gap,
                status: :green,
                total_population: 1000,
                affected_count: 0,
                affected_pct: 0.0,
                blocked_reason: nil
              }
            ]
          }
        }
      }

      props = Show.domain_card_props(verdict, :movies)
      assert props.headline =~ "vs TMDb"
      refute props.headline =~ "unavailable"
      assert props.unknown_count == 0
    end

    test "collaborations headline reports coverage" do
      verdict = %{
        domains: %{
          collaborations: %{
            status: :red,
            checks: [
              %{
                check: :missing_details,
                status: :red,
                total_population: 100,
                affected_count: 25,
                affected_pct: 25.0,
                blocked_reason: nil
              }
            ]
          }
        }
      }

      props = Show.domain_card_props(verdict, :collaborations)
      assert props.headline == "75.0% collaboration coverage"
    end
  end
end

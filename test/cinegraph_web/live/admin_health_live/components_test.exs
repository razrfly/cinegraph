defmodule CinegraphWeb.AdminHealthLive.ComponentsTest do
  # Pure render tests — no DB.
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest
  import CinegraphWeb.AdminHealthLive.Components

  describe "verdict_pill/1" do
    test "renders status label and color for green/amber/red/unknown" do
      green = render_component(&verdict_pill/1, status: :green)
      assert green =~ "Healthy"
      assert green =~ "bg-green-100 text-green-800"

      amber = render_component(&verdict_pill/1, status: :amber)
      assert amber =~ "Warning"
      assert amber =~ "bg-amber-100 text-amber-800"

      red = render_component(&verdict_pill/1, status: :red)
      assert red =~ "Critical"
      assert red =~ "bg-red-100 text-red-800"

      unknown = render_component(&verdict_pill/1, status: :unknown)
      assert unknown =~ "Unknown"
      assert unknown =~ "bg-zinc-100"
    end

    test "supports a custom label override" do
      html = render_component(&verdict_pill/1, status: :green, label: "Looks great")
      assert html =~ "Looks great"
      refute html =~ "Healthy"
    end
  end

  describe "stat_tile/1" do
    test "renders label, formatted count, and an SVG sparkline" do
      html =
        render_component(&stat_tile/1,
          label: "Movies+",
          count: 1234,
          sparkline: [1, 2, 3, 4, 5, 6, 7],
          tone: :blue
        )

      assert html =~ "Movies+"
      assert html =~ "1,234"
      assert html =~ "<svg"
      assert html =~ "polyline"
      assert html =~ "bg-blue-50"
    end

    test "0 count renders without crashing" do
      html = render_component(&stat_tile/1, label: "x", count: 0, sparkline: [])
      assert html =~ ">0<"
      assert html =~ "<svg"
    end
  end

  describe "sparkline/1" do
    test "≥2 points renders a polyline" do
      html = render_component(&sparkline/1, points: [10, 20, 30])
      assert html =~ "<svg"
      assert html =~ "<polyline"
      assert html =~ "points="
    end

    test "0 / 1 points renders empty SVG (no polyline)" do
      empty = render_component(&sparkline/1, points: [])
      assert empty =~ "<svg"
      refute empty =~ "<polyline"

      one = render_component(&sparkline/1, points: [42])
      assert one =~ "<svg"
      refute one =~ "<polyline"
    end

    test "constant series doesn't divide by zero" do
      html = render_component(&sparkline/1, points: [5, 5, 5, 5])
      assert html =~ "<polyline"
    end
  end

  describe "drift_card/1" do
    test "renders title, headline, signals, and a 'View details' button" do
      html =
        render_component(&drift_card/1,
          domain: :people,
          title: "PEOPLE",
          status: :red,
          headline: "73% have full TMDb data",
          signals: [
            %{label: "no profile_path", affected_count: 12_481, affected_pct: 1.86},
            %{label: "no biography", affected_count: 8_302, affected_pct: 1.24}
          ]
        )

      assert html =~ "PEOPLE"
      assert html =~ "73% have full TMDb data"
      assert html =~ "no profile_path"
      assert html =~ "12,481"
      assert html =~ "View details"
      assert html =~ ~s(phx-value-domain="people")
    end
  end

  describe "queue_strip/1" do
    test "renders queue rows from a snapshot" do
      snap = %{
        generated_at: ~U[2026-04-25 12:00:00Z],
        total_failures_last_hour: 0,
        queues: [
          %{
            name: :tmdb,
            available: 5,
            executing: 2,
            scheduled: 0,
            retryable: 0,
            discarded: 0,
            cancelled: 0,
            failures_last_hour: 0,
            longest_running_seconds: 0
          }
        ]
      }

      html = render_component(&queue_strip/1, snapshot: snap)
      assert html =~ "tmdb"
      assert html =~ ">5<"
      assert html =~ ">2<"
    end

    test "renders error fallback" do
      html = render_component(&queue_strip/1, snapshot: {:error, "down"})
      assert html =~ "Queue snapshot unavailable"
      assert html =~ "down"
    end
  end

  describe "trend_chart/1" do
    test "empty history shows the 'capturing' message" do
      html = render_component(&trend_chart/1, history: [])
      assert html =~ "Capturing"
    end

    test "single-day history shows the friendly fallback" do
      history = [
        %{captured_on: ~D[2026-04-25], payload: %{"overall_completeness_pct" => 72.5}}
      ]

      html = render_component(&trend_chart/1, history: history)
      assert html =~ "One snapshot so far"
      assert html =~ "72.5%"
    end

    test "≥2 days renders an SVG polyline" do
      history = [
        %{captured_on: ~D[2026-04-23], payload: %{"overall_completeness_pct" => 70.0}},
        %{captured_on: ~D[2026-04-24], payload: %{"overall_completeness_pct" => 72.0}},
        %{captured_on: ~D[2026-04-25], payload: %{"overall_completeness_pct" => 75.0}}
      ]

      html = render_component(&trend_chart/1, history: history)
      assert html =~ "<polyline"
      assert html =~ "70.0%"
      assert html =~ "75.0%"
    end

    test "rows missing payload pct are filtered out" do
      history = [
        %{captured_on: ~D[2026-04-25], payload: %{}}
      ]

      html = render_component(&trend_chart/1, history: history)
      # No valid points → falls through to capturing message
      assert html =~ "Capturing"
    end

    test "error fallback gracefully handles {:error, _}" do
      html = render_component(&trend_chart/1, history: {:error, "boom"})
      assert html =~ "Capturing"
    end
  end

  describe "status_classes/1" do
    test "returns Tailwind classes per status" do
      assert status_classes(:green) =~ "bg-green-50"
      assert status_classes(:amber) =~ "bg-amber-50"
      assert status_classes(:red) =~ "bg-red-50"
      assert status_classes(:unknown) =~ "bg-zinc-50"
      # Anything unrecognized falls back to neutral
      assert status_classes(:bogus) =~ "bg-zinc-50"
    end
  end
end

defmodule Cinegraph.Health.VerdictTest do
  # Pure-logic tests — no DB, no DataCase needed.
  # async: false because several tests mutate Application.put_env/2 for
  # :cinegraph, :health thresholds. Running concurrently would leak
  # thresholds across tests.
  use ExUnit.Case, async: false

  alias Cinegraph.Health.Verdict

  defp check(domain, check_name, pct, count, opts \\ []) do
    %{
      generated_at: ~U[2026-04-25 12:00:00Z],
      domain: domain,
      check: check_name,
      status: :unknown,
      total_population: 1000,
      affected_count: count,
      affected_pct: pct,
      examples: [],
      blocked_reason: Keyword.get(opts, :blocked_reason)
    }
  end

  describe "color_check/2" do
    test ":green when pct <= green_max" do
      thresholds = %{people: %{missing_biography: {30.0, 60.0}}}
      result = Verdict.color_check(check(:people, :missing_biography, 25.0, 250), thresholds)
      assert result.status == :green
    end

    test ":amber when pct > green_max and <= amber_max" do
      thresholds = %{people: %{missing_biography: {30.0, 60.0}}}
      result = Verdict.color_check(check(:people, :missing_biography, 45.0, 450), thresholds)
      assert result.status == :amber
    end

    test ":red when pct > amber_max" do
      thresholds = %{people: %{missing_biography: {30.0, 60.0}}}
      result = Verdict.color_check(check(:people, :missing_biography, 75.0, 750), thresholds)
      assert result.status == :red
    end

    test "exact green_max boundary is :green (inclusive)" do
      thresholds = %{people: %{x: {5.0, 15.0}}}
      result = Verdict.color_check(check(:people, :x, 5.0, 50), thresholds)
      assert result.status == :green
    end

    test "exact amber_max boundary is :amber (inclusive)" do
      thresholds = %{people: %{x: {5.0, 15.0}}}
      result = Verdict.color_check(check(:people, :x, 15.0, 150), thresholds)
      assert result.status == :amber
    end

    test "integer thresholds compare against affected_count, not pct" do
      thresholds = %{festivals: %{nominations_missing_movie: {0, 0}}}

      green =
        Verdict.color_check(check(:festivals, :nominations_missing_movie, 0.0, 0), thresholds)

      assert green.status == :green

      red =
        Verdict.color_check(check(:festivals, :nominations_missing_movie, 0.01, 1), thresholds)

      assert red.status == :red
    end

    test "blocked_reason forces :unknown regardless of pct" do
      thresholds = %{people: %{x: {5.0, 15.0}}}

      result =
        Verdict.color_check(
          check(:people, :x, 99.0, 990, blocked_reason: "DB unreachable"),
          thresholds
        )

      assert result.status == :unknown
    end

    test "missing threshold falls back to :default" do
      thresholds = %{default: {1.0, 5.0}}
      result = Verdict.color_check(check(:people, :unmapped, 3.0, 30), thresholds)
      assert result.status == :amber
    end

    test "no thresholds at all falls back to internal default {1.0, 10.0}" do
      result = Verdict.color_check(check(:people, :anything, 50.0, 500), %{})
      assert result.status == :red
    end
  end

  describe "compute/1" do
    test "domain status equals worst-check status" do
      thresholds = %{
        people: %{a: {1.0, 5.0}, b: {1.0, 5.0}}
      }

      Application.put_env(:cinegraph, :health, thresholds: thresholds)
      on_exit(fn -> Application.delete_env(:cinegraph, :health) end)

      verdict =
        Verdict.compute(%{
          people: [
            check(:people, :a, 0.5, 5),
            check(:people, :b, 50.0, 500)
          ]
        })

      assert verdict.status == :red
      assert verdict.domains.people.status == :red
      assert verdict.worst_check.check == :b
    end

    test "overall status is worst across domains" do
      thresholds = %{
        default: {1.0, 5.0},
        people: %{a: {1.0, 5.0}},
        movies: %{b: {1.0, 5.0}}
      }

      Application.put_env(:cinegraph, :health, thresholds: thresholds)
      on_exit(fn -> Application.delete_env(:cinegraph, :health) end)

      verdict =
        Verdict.compute(%{
          people: [check(:people, :a, 0.5, 5)],
          movies: [check(:movies, :b, 50.0, 500)]
        })

      assert verdict.status == :red
      assert verdict.domains.people.status == :green
      assert verdict.domains.movies.status == :red
    end

    test "all green returns :green overall" do
      thresholds = %{default: {10.0, 20.0}}
      Application.put_env(:cinegraph, :health, thresholds: thresholds)
      on_exit(fn -> Application.delete_env(:cinegraph, :health) end)

      verdict =
        Verdict.compute(%{
          people: [check(:people, :a, 5.0, 50)],
          movies: [check(:movies, :b, 5.0, 50)]
        })

      assert verdict.status == :green
    end

    test "empty input returns :unknown" do
      verdict = Verdict.compute(%{})
      assert verdict.status == :unknown
      assert verdict.worst_check == nil
    end

    test "domain priority: ties broken by people > movies > festivals > ratings" do
      thresholds = %{default: {1.0, 5.0}}
      Application.put_env(:cinegraph, :health, thresholds: thresholds)
      on_exit(fn -> Application.delete_env(:cinegraph, :health) end)

      verdict =
        Verdict.compute(%{
          ratings: [check(:ratings, :r1, 50.0, 500)],
          people: [check(:people, :p1, 50.0, 500)]
        })

      # Both red — but people takes priority for worst_check
      assert verdict.worst_check.domain == :people
    end
  end
end

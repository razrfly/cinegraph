defmodule Cinegraph.Freshness.PolicyTest do
  @moduledoc "#1096 Phase B — the pure staleness registry."
  use ExUnit.Case, async: true

  alias Cinegraph.Freshness.Policy

  @anchor ~U[2026-06-09 12:00:00Z]

  defp ttl_days(source, base_date, opts \\ []) do
    stale = Policy.stale_after("movie", source, base_date, @anchor, opts)
    DateTime.diff(stale, @anchor, :day)
  end

  describe "age-tiered TTLs (movie by release_date)" do
    test "new / recent / catalog / old tiers map to the source's TTLs" do
      # tmdb_details: new 7 · recent 30 · catalog 180 · old 365
      assert ttl_days("tmdb_details", ~D[2026-06-01]) == 7
      assert ttl_days("tmdb_details", ~D[2025-06-09]) == 30
      assert ttl_days("tmdb_details", ~D[2020-06-09]) == 180
      assert ttl_days("tmdb_details", ~D[1995-01-01]) == 365
    end

    test "watch_providers is the most volatile source" do
      assert ttl_days("watch_providers", ~D[2026-06-01]) == 3
      assert ttl_days("watch_providers", ~D[1995-01-01]) == 90
    end

    test "nil base_date defaults to the catalog tier" do
      assert ttl_days("omdb", nil) == 90
    end

    test ":empty responses wait @empty_multiplier (3x) longer" do
      assert ttl_days("tmdb_details", ~D[2026-06-01], status: :empty) == 21
    end

    test "person uses latest_credit tier thresholds (new <1y)" do
      stale = Policy.stale_after("person", "tmdb_person", ~D[2026-01-01], @anchor)
      assert DateTime.diff(stale, @anchor, :day) == 30
      old = Policy.stale_after("person", "tmdb_person", ~D[2024-01-01], @anchor)
      assert DateTime.diff(old, @anchor, :day) == 90
    end
  end

  describe "fixed-cadence (lists / festivals)" do
    test "flat 30-day cadence regardless of base_date" do
      stale = Policy.stale_after("list", "imdb_list", nil, @anchor)
      assert DateTime.diff(stale, @anchor, :day) == 30
    end

    test "per-entity ttl_override_days wins" do
      stale =
        Policy.stale_after("list", "imdb_list", nil, @anchor,
          metadata: %{"ttl_override_days" => 7}
        )

      assert DateTime.diff(stale, @anchor, :day) == 7
    end
  end

  describe "unknown source" do
    test "falls back to a 30-day default rather than crashing" do
      stale = Policy.stale_after("movie", "not_a_real_source", ~D[2020-01-01], @anchor)
      assert DateTime.diff(stale, @anchor, :day) == 30
    end
  end

  describe "error backoff" do
    test "doubles each attempt and caps at 7 days" do
      assert Policy.backoff(1) == 3600
      assert Policy.backoff(2) == 7200
      assert Policy.backoff(3) == 14_400
      assert Policy.backoff(50) == 7 * 86_400
    end
  end
end

defmodule Mix.Tasks.Predictions.ProgressLineTest do
  @moduledoc "The pure CLI status-line formatter (#1065 Phase 3)."
  use ExUnit.Case, async: true

  alias Mix.Tasks.Predictions.ProgressLine

  test "renders label, bar, fraction, current cell, throughput, ETA, failures" do
    line =
      ProgressLine.render(%{
        label: "matrix",
        done: 24,
        total: 70,
        current: "ebert/temporal/objective_only",
        throughput_per_min: 6.5,
        eta_ms: 7 * 60_000,
        failed: 2
      })

    assert line =~ "matrix"
    assert line =~ "24/70"
    assert line =~ "ebert/temporal/objective_only"
    assert line =~ "6.5/min"
    assert line =~ "ETA ~7.0m"
    assert line =~ "2 failed"
    # a filled + empty bar segment
    assert line =~ "█"
    assert line =~ "░"
  end

  test "omits throughput/ETA when unknown and shows an em dash for a missing current cell" do
    line = ProgressLine.render(%{label: "promote", done: 0, total: 3})

    assert line =~ "promote"
    assert line =~ "0/3"
    assert line =~ "—"
    refute line =~ "/min"
    refute line =~ "ETA"
    assert line =~ "0 failed"
  end

  test "ETA under a minute renders in seconds" do
    assert ProgressLine.render(%{label: "m", done: 1, total: 2, eta_ms: 8_000}) =~ "ETA ~8s"
  end

  test "promote-style line carries a running-average ETA" do
    line =
      ProgressLine.render(%{
        label: "promote",
        done: 2,
        total: 5,
        current: "afi_100",
        throughput_per_min: 1.2,
        eta_ms: 90_000,
        failed: 0
      })

    assert line =~ "promote"
    assert line =~ "2/5"
    assert line =~ "afi_100"
    assert line =~ "ETA ~1.5m"
  end
end

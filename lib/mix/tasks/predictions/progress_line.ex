defmodule Mix.Tasks.Predictions.ProgressLine do
  @moduledoc """
  A rewriting one-line CLI progress indicator for `predictions.matrix` / `predictions.promote`
  (#1065 Session 2, Phase 3).

  Reuses the repo's in-place status-line pattern (`IO.write("\\r\\e[K …")` — carriage-return +
  erase-to-EOL, as in `Mix.Tasks.Db.PullProduction`). `render/1` is a pure formatter (unit-testable
  without IO); `write/1` paints it; `clear/0` wipes the line before the final summary prints.

      matrix  ▕██████░░░░░░░░░░░░░░▏ 24/70 · ebert/temporal/objective_only · 6.5/min · ETA ~7m · 0 failed
  """

  @bar_width 20

  @doc """
  Format a progress snapshot into the status line (no IO).

  `snapshot` keys: `:label`, `:done`, `:total` (required); optional `:current`,
  `:throughput_per_min`, `:eta_ms`, `:failed`.
  """
  def render(%{label: label, done: done, total: total} = s) do
    [
      "#{label}  #{bar(done, total)} #{done}/#{total}",
      Map.get(s, :current) || "—",
      fmt_rate(Map.get(s, :throughput_per_min)),
      fmt_eta(Map.get(s, :eta_ms)),
      "#{Map.get(s, :failed, 0)} failed"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  @doc "Paint the status line in place (carriage-return + erase-to-end-of-line)."
  def write(snapshot), do: IO.write("\r\e[K" <> render(snapshot))

  @doc "Erase the current status line so a final summary starts clean."
  def clear, do: IO.write("\r\e[K")

  # ── internals ───────────────────────────────────────────────────────────────────

  defp bar(done, total) do
    total = max(total, 1)

    filled =
      done |> Kernel./(total) |> Kernel.*(@bar_width) |> round() |> min(@bar_width) |> max(0)

    "▕" <> String.duplicate("█", filled) <> String.duplicate("░", @bar_width - filled) <> "▏"
  end

  defp fmt_rate(nil), do: nil
  defp fmt_rate(rate), do: "#{:erlang.float_to_binary(rate * 1.0, decimals: 1)}/min"

  defp fmt_eta(nil), do: nil
  defp fmt_eta(ms), do: "ETA ~#{dur(ms)}"

  defp dur(ms) when ms < 60_000, do: "#{round(ms / 1000)}s"
  defp dur(ms), do: "#{Float.round(ms / 60_000, 1)}m"
end

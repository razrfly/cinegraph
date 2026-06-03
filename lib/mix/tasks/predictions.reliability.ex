defmodule Mix.Tasks.Predictions.Reliability do
  @moduledoc """
  Show the **reliability grade** of every list's active prediction model at a glance (#1039).

  One honest, conservative, gamed-proof trust grade per list — the headline is the Wilson-95
  *lower bound* of held-out recall@K (never the point estimate), and independent failures
  (identity calibration, stale frontier, stale model, failed pre-registration, too few positives,
  no lift over popularity) can only lower the grade. A list with no active model, or too little
  evidence, is reported honestly rather than given a flattering number.

      mix predictions.reliability            # lists with an active model
      mix predictions.reliability --all      # include inactive lists
      mix predictions.reliability --json

  Grades: HIGH ≥ 50% · MODERATE ≥ 30% · LOW < 30% · INSUFFICIENT (no headline). Bands gate the
  lower bound, so they are deliberately demanding.
  """
  use Mix.Task

  alias Cinegraph.Movies.MovieLists
  alias Cinegraph.Predictions.Reliability
  alias Cinegraph.Scoring.Bus

  @shortdoc "Per-list prediction reliability grade (honest, conservative trust score)"

  @impl Mix.Task
  def run(args) do
    Cinegraph.Predictions.TaskSupport.start_lean()

    {opts, _, _} = OptionParser.parse(args, strict: [json: :boolean, all: :boolean])

    lists =
      if opts[:all],
        do: MovieLists.list_all_movie_lists(),
        else: MovieLists.list_active_movie_lists()

    rows =
      lists
      |> Enum.map(fn list ->
        case Bus.active_model(list.source_key) do
          nil ->
            %{source_key: list.source_key, name: list.name, reliability: nil}

          model ->
            %{source_key: list.source_key, name: list.name, reliability: Reliability.score(model)}
        end
      end)

    if opts[:json], do: print_json(rows), else: print_table(rows)
  end

  # ── human table ───────────────────────────────────────────────────────────────
  defp print_table(rows) do
    Mix.shell().info("""

    PREDICTION RELIABILITY — Wilson-95 lower bound, conservative bands
    (HIGH ≥ 50%  ·  MOD ≥ 30%  ·  LOW < 30%  ·  INSUF = too little evidence)

      GRADE   HEADLINE  CALIB     LIST                            TOP REASON
    """)

    Enum.each(rows, fn row ->
      Mix.shell().info("  " <> format_row(row))
    end)

    Mix.shell().info("")
  end

  defp format_row(%{reliability: nil, name: name}) do
    "#{pad("—", 7)} #{pad("—", 9)} #{pad("—", 9)} #{pad(name, 31)} no active prediction model"
  end

  defp format_row(%{reliability: r, name: name}) do
    "#{pad(grade_label(r.grade), 7)} #{pad(headline(r.headline_pct), 9)} #{pad(r.calibration || "—", 9)} #{pad(name, 31)} #{top_reason(r)}"
  end

  defp top_reason(%{band_grade: b, grade: g, reasons: [first | _]}) when b != g,
    do: "capped from #{grade_label(b)}: #{first}"

  defp top_reason(%{reasons: [first | _]}), do: first
  defp top_reason(%{grade: :high}), do: "clears every gate"
  defp top_reason(_), do: "accuracy lower bound only (no integrity penalties)"

  # ── json ────────────────────────────────────────────────────────────────────────
  defp print_json(rows) do
    IO.puts(Jason.encode!(Enum.map(rows, &jsonable/1), pretty: true))
  end

  defp jsonable(%{reliability: nil} = row),
    do: %{source_key: row.source_key, name: row.name, reliability: nil}

  defp jsonable(%{reliability: r} = row) do
    {lo, hi} = r.ci

    %{
      source_key: row.source_key,
      name: row.name,
      reliability: %{
        grade: to_string(r.grade),
        band_grade: to_string(r.band_grade),
        headline_pct: r.headline_pct,
        ci: [lo, hi],
        lift: r.lift,
        power: r.power,
        calibration: r.calibration,
        freshness: %{
          fresh?: r.freshness.fresh?,
          cutoff_source: to_string(r.freshness.cutoff_source),
          warnings: r.freshness.warnings
        },
        sufficient?: r.sufficient?,
        reasons: r.reasons
      }
    }
  end

  # ── helpers ───────────────────────────────────────────────────────────────────
  defp grade_label(:high), do: "HIGH"
  defp grade_label(:moderate), do: "MOD"
  defp grade_label(:low), do: "LOW"
  defp grade_label(:insufficient), do: "INSUF"

  defp headline("—"), do: "—"
  defp headline(pct) when is_number(pct), do: "#{pct}%"

  defp pad(v, n), do: v |> to_string() |> String.pad_trailing(n)
end

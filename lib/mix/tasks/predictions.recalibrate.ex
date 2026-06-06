defmodule Mix.Tasks.Predictions.Recalibrate do
  @shortdoc "Refit served models' probability calibration from reproduced holdout pairs (#1074)"

  @moduledoc """
  Refit the **served** models' Platt calibration (#1074) — no retraining, no holdout re-spend,
  no grade changes. The model is already chosen; this re-derives its recorded holdout evaluation
  (`Trainer.holdout_pairs/1`) and fits the new two-stage balanced Platt map on those pairs.

      mix predictions.recalibrate                       # dry-run, every served list
      mix predictions.recalibrate --only 1001_movies,afi_100
      mix predictions.recalibrate --commit              # write calibration + brier

  Per list it reports: slope old→new, `informative?` old→new, Brier (identity vs old vs new),
  and the **reproduction check** — recall@K recomputed from the reproduced pairs must match
  `integrity_report["recall_at_k"]` (a mismatch means catalog/code drift since promotion; the
  task refuses to commit that list). A commit is also refused when the new Brier is worse than
  the identity baseline (a calibration worse than no calibration stays gated).

  `--commit` updates ONLY `prediction_models.calibration` + `integrity_report["brier"]` —
  weights, recall, grades, and the serving pointer are untouched.
  """
  use Mix.Task

  alias Cinegraph.Movies.MovieLists
  alias Cinegraph.Predictions.{Credibility, ProbabilityCalibration, Trainer}
  alias Cinegraph.Repo
  alias Cinegraph.Scoring.Bus

  # Reproduced recall must match the stored recall to this absolute tolerance (stored values are
  # rounded to 4 decimals).
  @recall_tolerance 1.0e-3

  @impl true
  def run(args) do
    Mix.Task.run("app.start")
    Logger.configure(level: :warning)

    {opts, _, _} = OptionParser.parse(args, strict: [only: :string, commit: :boolean])
    commit? = opts[:commit] == true
    only = opts[:only] && opts[:only] |> String.split(",", trim: true) |> MapSet.new()

    lists =
      MovieLists.all_displayable()
      |> Enum.filter(fn l -> is_nil(only) or MapSet.member?(only, l.source_key) end)

    Mix.shell().info(
      "\nRecalibration #{if commit?, do: "(COMMIT)", else: "(dry-run — pass --commit to write)"}\n"
    )

    results = Enum.map(lists, &recalibrate_list(&1, commit?))

    ok = Enum.count(results, &(&1 in [:committed, :would_commit]))
    refused = Enum.count(results, &(&1 == :refused))
    skipped = Enum.count(results, &(&1 == :skipped))
    ok_label = if commit?, do: "committed", else: "ready to commit"

    Mix.shell().info(
      "\n#{length(results)} lists: #{ok} #{ok_label} · #{refused} refused · #{skipped} skipped (no model / not reproducible)"
    )
  end

  defp recalibrate_list(list, commit?) do
    sk = list.source_key

    case Bus.active_model(sk) do
      nil ->
        Mix.shell().info("  #{pad(sk)} — no served model, skipped")
        :skipped

      model ->
        case Trainer.holdout_pairs(model) do
          {:error, reason} ->
            Mix.shell().info("  #{pad(sk)} — pairs not reproducible: #{inspect(reason)}")
            :skipped

          {:ok, pairs, recomputed_recall} ->
            assess_and_maybe_commit(sk, model, pairs, recomputed_recall, commit?)
        end
    end
  end

  defp assess_and_maybe_commit(sk, model, pairs, recomputed_recall, commit?) do
    stored_recall = model.integrity_report["recall_at_k"]

    repro_ok? =
      is_number(stored_recall) and is_number(recomputed_recall) and
        abs(recomputed_recall - stored_recall) < @recall_tolerance

    {scores, labels} = Enum.unzip(pairs)
    new_calib = ProbabilityCalibration.fit(scores, labels)

    brier_identity = Credibility.brier_calibrated(pairs, %{"method" => "identity"})
    brier_old = Credibility.brier_calibrated(pairs, model.calibration)
    brier_new = Credibility.brier_calibrated(pairs, new_calib)

    informative_old = ProbabilityCalibration.informative?(model.calibration)
    informative_new = ProbabilityCalibration.informative?(new_calib)

    brier_ok? = is_number(brier_new) and is_number(brier_identity) and brier_new <= brier_identity

    Mix.shell().info(
      "  #{pad(sk)} #{model.backtest_strategy} · slope #{slope(model.calibration)} → #{slope(new_calib)}" <>
        " · informative #{informative_old} → #{informative_new}" <>
        " · brier id/old/new #{fmt(brier_identity)}/#{fmt(brier_old)}/#{fmt(brier_new)}" <>
        " · repro #{if repro_ok?, do: "✓", else: "✗ (#{fmt(recomputed_recall)} vs stored #{fmt(stored_recall)})"}"
    )

    cond do
      not repro_ok? ->
        Mix.shell().info("       ↳ REFUSED: reproduced recall doesn't match the stored holdout")
        :refused

      not brier_ok? ->
        Mix.shell().info("       ↳ REFUSED: new Brier worse than the identity baseline")
        :refused

      commit? ->
        report = Map.put(model.integrity_report, "brier", brier_new)

        model
        |> Ecto.Changeset.change(calibration: new_calib, integrity_report: report)
        |> Repo.update!()

        Mix.shell().info("       ↳ committed (calibration + brier only)")
        :committed

      true ->
        :would_commit
    end
  end

  defp slope(%{"method" => "platt", "a" => a}) when is_number(a),
    do: :erlang.float_to_binary(a * 1.0, decimals: 3)

  defp slope(%{"method" => "identity"}), do: "identity"
  defp slope(_), do: "—"

  defp fmt(n) when is_number(n), do: :erlang.float_to_binary(n * 1.0, decimals: 4)
  defp fmt(_), do: "—"

  defp pad(sk), do: String.pad_trailing(to_string(sk), 26)
end

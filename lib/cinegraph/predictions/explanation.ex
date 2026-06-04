defmodule Cinegraph.Predictions.Explanation do
  @moduledoc """
  Human-facing explanation of a list's active prediction model (#1061 Session 2) — the read-model
  behind *"We predict the Criterion Collection at 57% using the linear_logreg model; here are the
  weights that drive it."*

  Pure read, no writes. Reads the served `%Model{}` (via `Bus.active_model/1`), grades it with the
  conservative `Reliability` scorer, and tags **every weight** as objective vs canon-overlap
  (reusing `Trainer.canon_overlap_codes/1`) with a human label from the metric-definition catalog —
  so a UI can honestly separate independent signal from circular signal. `:rivals` surfaces the top
  competing recorded runs from the ledger.

  The actual `/predictions` page rendering lives in the public-UI work (#1038/#1049); this delivers
  the payload + the honesty tagging so that page is a thin consumer.
  """
  import Ecto.Query

  alias Cinegraph.Metrics
  alias Cinegraph.Predictions.{ExperimentLedger, ModelRegistry, Reliability, Trainer}
  alias Cinegraph.Repo
  alias Cinegraph.Scoring.Bus

  @rank_sql "COALESCE((? ->> 'objective_recall_at_k')::float, (? ->> 'recall_at_k')::float)"

  @doc """
  Build the explanation payload for a list, or `{:error, :no_active_model}` when nothing is served.

  Returns `{:ok, %{list, model_class, model_label, strategy, serving_kind, headline_accuracy,
  grade, lift, circularity, weights: [%{code, weight, bucket, label}], rivals: [...]}}`.
  """
  def for_list(source_key) when is_binary(source_key) do
    case Bus.active_model(source_key) do
      nil ->
        {:error, :no_active_model}

      model ->
        scorecard = Reliability.score(model)
        canon = MapSet.new(Trainer.canon_overlap_codes(source_key))

        {:ok,
         %{
           list: source_key,
           model_class: model.model_class,
           model_label: class_label(model.model_class),
           strategy: model.backtest_strategy,
           serving_kind: serving_kind(model.model_class),
           headline_accuracy: scorecard.headline_pct,
           grade: scorecard.grade,
           lift: scorecard.lift,
           circularity: scorecard.circularity,
           weights: tag_weights(model.weights, canon),
           rivals: rivals(source_key, model)
         }}
    end
  end

  # ── weights → tagged, labeled, sorted by |weight| ────────────────────────────────
  defp tag_weights(weights, canon) when is_map(weights) do
    weights
    |> Enum.map(fn {code, w} ->
      %{
        code: code,
        weight: w,
        bucket: if(code in canon, do: :canon_overlap, else: :objective),
        label: label_for(code)
      }
    end)
    |> Enum.sort_by(&abs(&1.weight), :desc)
  end

  defp tag_weights(_weights, _canon), do: []

  # Human label from the catalog; fall back to the raw code (e.g. lens codes aren't catalogued).
  defp label_for(code) do
    case Metrics.get_metric_definition(code) do
      %{name: name} when is_binary(name) -> name
      _ -> code
    end
  end

  # ── rivals: top OTHER recorded runs for the list ─────────────────────────────────
  # Exclude the active combo in the WHERE (CodeRabbit #1064): rejecting after a `limit: 6` could
  # drop genuine rivals ranked below position 6 when the active combo appears in the top 6.
  defp rivals(source_key, model) do
    from(e in ExperimentLedger,
      where:
        e.status == "ok" and e.source_key == ^source_key and
          not (e.model_class == ^model.model_class and
                 e.backtest_strategy == ^model.backtest_strategy),
      order_by: [desc_nulls_last: fragment(@rank_sql, e.metrics, e.metrics)],
      limit: 5
    )
    |> Repo.all()
    |> Enum.map(fn r ->
      %{
        model_class: r.model_class,
        strategy: r.backtest_strategy,
        feature_bucket: r.feature_bucket,
        grade: r.grade,
        objective_recall: r.metrics["objective_recall_at_k"] || r.metrics["recall_at_k"]
      }
    end)
  end

  # Resolve label/serving_kind from the registry; fall back gracefully so a deprecated/retired
  # class that is still serving an old model still renders.
  defp class_label(class) do
    case ModelRegistry.fetch(class) do
      {:ok, mod} -> mod.label()
      _ -> class
    end
  end

  defp serving_kind(class) do
    case ModelRegistry.fetch(class) do
      {:ok, mod} -> mod.serving_kind()
      _ -> :weight_map
    end
  end
end

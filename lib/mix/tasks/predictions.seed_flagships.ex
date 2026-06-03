defmodule Mix.Tasks.Predictions.SeedFlagships do
  @moduledoc """
  Seed an active prediction model for each canonical "flagship" list that has none (#1040 S3).

  For every list below it registers a fresh pre-registration and runs the integrity-protocol
  trainer (`Trainer.train(save: true)`) once — spending that list's sacred holdout a single time,
  fitting calibration, persisting the model, and pointing the list at it. Strategy is chosen per
  list topology: **static** k-fold for the all-time canon lists (which lack temporal spread), and
  **temporal** for `national_film_registry` (which accretes yearly).

  Honest by construction: a list with sparse/identity-calibratable data will train a model that
  `mix predictions.reliability` then grades Low/Insufficient — that's the correct signal, not a bug.

      mix predictions.seed_flagships
      mix predictions.seed_flagships --json
      mix predictions.seed_flagships --only criterion,letterboxd_top_250
  """
  use Mix.Task

  alias Cinegraph.Predictions.{PreRegistration, Trainer}

  @shortdoc "Seed prediction models for the listless flagship canonical lists (#1040)"

  # source_key => backtest strategy. All-time canon lists use static k-fold; NFR accretes yearly.
  @flagships %{
    "afi_100" => "static",
    "sight_sound_critics_2022" => "static",
    "sight_sound_directors_2022" => "static",
    "letterboxd_top_250" => "static",
    "ebert_great_movies" => "static",
    "criterion" => "static",
    "tspdt_1000" => "static",
    "national_film_registry" => "temporal"
  }

  @threshold 0.20

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")
    {opts, _, _} = OptionParser.parse(args, strict: [json: :boolean, only: :string])

    targets =
      case opts[:only] do
        nil -> Map.keys(@flagships)
        csv -> String.split(csv, ",", trim: true)
      end

    results = Enum.map(targets, &seed_one(&1, Map.get(@flagships, &1, "static")))

    if opts[:json] do
      IO.puts(Jason.encode!(results, pretty: true))
    else
      Enum.each(results, &print_result/1)
    end
  end

  defp seed_one(source_key, strategy) do
    {:ok, prereg} =
      PreRegistration.register(%{
        source_key: source_key,
        expected_top_features: %{"note" => "auto-registered by mix predictions.seed_flagships"},
        expected_accuracy_range: %{"min" => @threshold, "max" => 1.0},
        failure_threshold: :erlang.float_to_binary(@threshold, decimals: 2)
      })

    case Trainer.train(source_key,
           granularity: :data_point,
           save: true,
           prereg: prereg,
           backtest_strategy: strategy
         ) do
      {:ok, summary} ->
        %{
          source_key: source_key,
          strategy: strategy,
          status: "ok",
          model_id: summary[:model_id],
          recall_at_k: summary.integrity_report["recall_at_k"],
          calibration: summary.calibration["method"],
          verdict: summary.verdict["passed"]
        }

      {:error, reason} ->
        %{source_key: source_key, strategy: strategy, status: "error", reason: inspect(reason)}
    end
  end

  defp print_result(%{status: "ok"} = r) do
    Mix.shell().info(
      "✓ #{String.pad_trailing(r.source_key, 28)} #{String.pad_trailing(r.strategy, 9)} " <>
        "model ##{r.model_id} · recall@K #{fmt(r.recall_at_k)} · calib #{r.calibration} · passed=#{r.verdict}"
    )
  end

  defp print_result(%{status: "error"} = r) do
    Mix.shell().info("✗ #{String.pad_trailing(r.source_key, 28)} #{r.strategy}  — #{r.reason}")
  end

  defp fmt(nil), do: "—"
  defp fmt(n) when is_float(n), do: :erlang.float_to_binary(n, decimals: 4)
  defp fmt(n), do: to_string(n)
end

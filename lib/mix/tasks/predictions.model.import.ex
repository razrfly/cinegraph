defmodule Mix.Tasks.Predictions.Model.Import do
  @shortdoc "Import a prediction-model bundle (idempotent; the prod-side half of #1043)"

  @moduledoc """
  Import a bundle written by `mix predictions.model.export`. Idempotent and transactional;
  refuses on substrate mismatch (Gate 1) and writes the holdout measurement verbatim (Gate 2).
  Runs in prod via `bin/cinegraph eval` (see MAINTENANCE.md) or locally for testing.

      mix predictions.model.import priv/prediction_models/1001_movies-<hash>.json
  """
  use Mix.Task

  alias Cinegraph.Predictions.ModelBundle

  @impl true
  def run([path]) do
    Mix.Task.run("app.start")
    Logger.configure(level: :warning)

    bundle = path |> File.read!() |> Jason.decode!()

    case ModelBundle.import(bundle) do
      {:ok, result} ->
        Mix.shell().info(
          "#{bundle["source_key"]}: #{result.status} (model_id #{result.model_id}, " <>
            "#{result.weights_hash}) · activated: #{result.activated}"
        )

      {:error, reason} ->
        Mix.raise("import refused: #{inspect(reason)}")
    end
  end

  def run(_), do: Mix.raise("usage: mix predictions.model.import <bundle.json>")
end

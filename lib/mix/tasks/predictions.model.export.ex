defmodule Mix.Tasks.Predictions.Model.Export do
  @shortdoc "Export served prediction models as reviewable JSON bundles (#1043)"

  @moduledoc """
  Export a list's ACTIVE model (prereg + artifact + substrate fingerprint) to
  `priv/prediction_models/<source_key>-<weights_hash>.json` — small, deterministic, git-trackable.

      mix predictions.model.export --list 1001_movies
      mix predictions.model.export --all
  """
  use Mix.Task

  alias Cinegraph.Predictions.ModelBundle

  @impl true
  def run(args) do
    Mix.Task.run("app.start")
    Logger.configure(level: :warning)

    {opts, _, _} = OptionParser.parse(args, strict: [list: :string, all: :boolean])

    bundles =
      cond do
        opts[:all] ->
          ModelBundle.export_all()

        opts[:list] ->
          [{opts[:list], ModelBundle.export(opts[:list])}]

        true ->
          Mix.raise("pass --list SOURCE_KEY or --all")
      end

    Enum.each(bundles, fn
      {sk, {:ok, bundle}} ->
        path = ModelBundle.write!(bundle)

        Mix.shell().info(
          "  #{String.pad_trailing(sk, 26)} #{bundle["model"]["weights_hash"]} → #{Path.relative_to_cwd(path)}"
        )

      {sk, {:error, reason}} ->
        Mix.shell().info("  #{String.pad_trailing(sk, 26)} skipped: #{inspect(reason)}")
    end)

    Mix.shell().info(
      "\n#{length(bundles)} bundle(s) written. They are reviewable artifacts — commit them."
    )
  end
end

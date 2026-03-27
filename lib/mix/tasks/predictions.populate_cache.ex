defmodule Mix.Tasks.Predictions.PopulateCache do
  @moduledoc """
  Populates the prediction cache by running the comprehensive predictions calculator.

  Calculates 2020s predictions, historical validation for all decades, and profile
  comparison, then writes results to the prediction_cache database table.

  ## Usage

      mix predictions.populate_cache
      mix predictions.populate_cache --profile "Balanced"
      mix predictions.populate_cache --all-profiles

  ## Options

    * `--profile` - weight profile name (default: default profile from DB)
    * `--all-profiles` - calculate for all profiles

  """
  use Mix.Task

  @shortdoc "Populate the prediction cache for the UI"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, invalid} =
      OptionParser.parse(args,
        strict: [
          profile: :string,
          all_profiles: :boolean
        ]
      )

    if invalid != [] do
      flags = Enum.map_join(invalid, ", ", fn {flag, _} -> flag end)
      Mix.raise("Unknown option(s): #{flags}")
    end

    alias Cinegraph.Workers.ComprehensivePredictionsCalculator
    alias Cinegraph.Metrics.ScoringService

    if Keyword.get(opts, :all_profiles, false) do
      profiles = ScoringService.get_all_profiles()
      Mix.shell().info("Populating cache for #{length(profiles)} profiles...")

      Enum.each(profiles, fn profile ->
        run_for_profile(profile)
      end)
    else
      profile =
        case Keyword.get(opts, :profile) do
          nil ->
            ScoringService.get_default_profile()

          name ->
            ScoringService.get_profile(name) ||
              Mix.raise("Profile not found: #{name}")
        end

      run_for_profile(profile)
    end

    Mix.shell().info("\nDone. Reload /admin/predictions to see results.")
  end

  defp run_for_profile(profile) do
    alias Cinegraph.Workers.ComprehensivePredictionsCalculator

    Mix.shell().info("Calculating predictions for profile: #{profile.name}...")

    job = %Oban.Job{args: %{"profile_id" => profile.id}}

    ComprehensivePredictionsCalculator.perform(job)
    Mix.shell().info("  ✓ #{profile.name} — cache populated successfully")
  end
end

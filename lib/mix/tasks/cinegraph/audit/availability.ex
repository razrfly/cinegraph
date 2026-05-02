defmodule Mix.Tasks.Cinegraph.Audit.Availability do
  @moduledoc """
  Audit Where to Watch availability coverage, freshness, catalog health, and queues.

  ## Usage

      mix cinegraph.audit.availability
      mix cinegraph.audit.availability --json
      mix cinegraph.audit.availability --limit 25 --region PL --stale-days 14
  """
  use Mix.Task

  alias Cinegraph.Health.AvailabilityAudit

  @shortdoc "Audit watch availability coverage and freshness"

  @doc false
  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, invalid} =
      OptionParser.parse(args,
        strict: [
          json: :boolean,
          limit: :integer,
          region: :string,
          stale_days: :integer,
          "stale-days": :integer
        ]
      )

    raise_invalid_options!(invalid)

    audit_opts = audit_opts(opts)
    result = AvailabilityAudit.audit(audit_opts)

    if Keyword.get(opts, :json, false) do
      result |> Jason.encode!(pretty: true) |> IO.puts()
    else
      print_summary(result)
    end
  end

  defp audit_opts(opts) do
    opts
    |> Keyword.take([:limit, :region, :stale_days])
    |> Keyword.merge(stale_days_option(opts))
  end

  defp stale_days_option(opts) do
    case Keyword.get(opts, :"stale-days") do
      nil -> []
      value -> [stale_days: value]
    end
  end

  defp print_summary(result) do
    Mix.shell().info(
      "Availability audit — region #{result.region}, generated #{result.generated_at}"
    )

    Mix.shell().info("")
    Mix.shell().info("summary:")
    Enum.each(result.summary, fn {key, value} -> Mix.shell().info("  #{key}: #{value}") end)
    Mix.shell().info("")
    Mix.shell().info("coverage:")
    Enum.each(result.coverage, fn {key, value} -> Mix.shell().info("  #{key}: #{value}%") end)
    Mix.shell().info("")
    Mix.shell().info("freshness:")

    Enum.each(result.freshness, fn {key, value} ->
      Mix.shell().info("  #{key}: #{inspect(value)}")
    end)

    Mix.shell().info("")
    Mix.shell().info("errors:")
    Mix.shell().info("  current_error_rows: #{result.errors.current_error_rows}")
    Mix.shell().info("")
    Mix.shell().info("recommended commands:")
    Enum.each(result.recommended_commands, fn command -> Mix.shell().info("  #{command}") end)
  end

  defp raise_invalid_options!([]), do: :ok
  defp raise_invalid_options!(invalid), do: Mix.raise("invalid option(s): #{inspect(invalid)}")
end

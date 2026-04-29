defmodule Mix.Tasks.Cinegraph.Prod.Audit.YearDiscovery do
  @moduledoc """
  Run the YearDiscoveryWorker audit against production via
  `kamal app exec`. Calls `Cinegraph.Health.YearDiscovery.audit/1` inside
  the running prod container and prints the result locally.

  ## Usage

      mix cinegraph.prod.audit.year_discovery              # 7 days
      mix cinegraph.prod.audit.year_discovery --days 30
      mix cinegraph.prod.audit.year_discovery --json       # single-line JSON for piping

  Requires the `kamal` CLI on PATH (installed via mise in this project).
  See MAINTENANCE.md → "Audits & ad-hoc reports".
  """
  use Mix.Task

  @shortdoc "Audit YearDiscoveryWorker health on production"

  alias Cinegraph.ProdRpc

  @impl Mix.Task
  def run(args) do
    {opts, _, invalid} = OptionParser.parse(args, strict: [json: :boolean, days: :integer])
    raise_invalid_options!(invalid)

    # See prod/health.ex: skip app.start to keep stdout clean for jq.

    days =
      case Keyword.get(opts, :days, 7) do
        n when is_integer(n) and n > 0 -> n
        other -> Mix.raise("--days must be a positive integer, got: #{inspect(other)}")
      end

    expr = ~s|IO.puts(Jason.encode!(Cinegraph.Health.YearDiscovery.audit(days: #{days})))|

    case ProdRpc.eval_json(expr) do
      {:ok, audit} -> ProdRpc.print(audit, opts)
      {:error, reason} -> ProdRpc.print_error(reason)
    end
  end

  defp raise_invalid_options!([]), do: :ok

  defp raise_invalid_options!(invalid) do
    Mix.raise("invalid option(s): #{inspect(invalid)}")
  end
end

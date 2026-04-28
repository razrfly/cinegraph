defmodule Mix.Tasks.Cinegraph.Prod.Completeness do
  @moduledoc """
  Read the production catalog completeness snapshot via `kamal app exec`
  (#739 Phase C). Calls `Cinegraph.Health.Completeness.run/0` (default) or
  `Cinegraph.Health.Completeness.history(N)` (with `--history N`) inside
  the running prod container and prints the result locally.

  ## Usage

      mix cinegraph.prod.completeness                # one snapshot, pretty JSON
      mix cinegraph.prod.completeness --history 30   # 30-day series
      mix cinegraph.prod.completeness --json         # single-line JSON for jq

  Requires the `kamal` CLI on PATH (installed via mise in this project).
  See MAINTENANCE.md.
  """
  use Mix.Task

  @shortdoc "Read prod completeness snapshot or history"

  alias Cinegraph.ProdRpc

  @impl Mix.Task
  def run(args) do
    {opts, _, invalid} = OptionParser.parse(args, strict: [json: :boolean, history: :integer])

    if invalid != [] do
      Mix.raise("Invalid arguments: #{inspect(invalid)}")
    end

    # See note in prod/health.ex: skip app.start to keep stdout clean for jq.

    expr =
      case Keyword.get(opts, :history) do
        nil ->
          ~s|IO.puts(Jason.encode!(Cinegraph.Health.Completeness.run()))|

        n when is_integer(n) and n > 0 ->
          ~s|IO.puts(Jason.encode!(Cinegraph.Health.Completeness.history(#{n})))|

        other ->
          Mix.raise("--history must be a positive integer, got: #{inspect(other)}")
      end

    case ProdRpc.eval_json(expr) do
      {:ok, result} -> ProdRpc.print(result, opts)
      {:error, reason} -> ProdRpc.print_error(reason)
    end
  end
end

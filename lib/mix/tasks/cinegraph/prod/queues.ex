defmodule Mix.Tasks.Cinegraph.Prod.Queues do
  @moduledoc """
  Read the production Oban queue snapshot via `kamal app exec` (#739
  Phase C). Calls `Cinegraph.Health.Queues.snapshot/0` inside the running
  prod container and prints the result locally.

  ## Usage

      mix cinegraph.prod.queues           # pretty-printed JSON
      mix cinegraph.prod.queues --json    # single-line JSON for piping

  Requires the `kamal` CLI on PATH (installed via mise in this project).
  See MAINTENANCE.md.
  """
  use Mix.Task

  @shortdoc "Read prod queue snapshot"

  alias Cinegraph.ProdRpc

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [json: :boolean])
    # See prod/health.ex: skip app.start to keep stdout clean for jq.

    expr = ~s|IO.puts(Jason.encode!(Cinegraph.Health.Queues.snapshot(bypass_cache: true)))|

    case ProdRpc.eval_json(expr) do
      {:ok, snapshot} -> ProdRpc.print(snapshot, opts)
      {:error, reason} -> ProdRpc.print_error(reason)
    end
  end
end

defmodule Mix.Tasks.Cinegraph.Prod.Health do
  @moduledoc """
  Read `/admin/health`'s verdict from production over SSH (#739 Phase C).
  No DB pull required — calls `Cinegraph.Health.Facade.compute_full_verdict/0`
  on the prod node and pretty-prints the result locally.

  ## Usage

      mix cinegraph.prod.health           # pretty-printed JSON
      mix cinegraph.prod.health --json    # single-line JSON for piping to jq

  Requires `REMOTE_APP_BIN` env var. See MAINTENANCE.md.
  """
  use Mix.Task

  @shortdoc "Read /admin/health verdict from production"

  alias Cinegraph.ProdRpc

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [json: :boolean])
    # Intentionally NOT calling Mix.Task.run("app.start") — this task only
    # uses System.cmd + Jason (no DB, no supervision tree). Skipping app.start
    # avoids ~20+ lines of dev-side log noise that would otherwise mix with
    # the JSON output meant for piping into jq.

    expr = ~s|IO.puts(Jason.encode!(Cinegraph.Health.Facade.compute_full_verdict()))|

    case ProdRpc.eval_json(expr) do
      {:ok, verdict} -> ProdRpc.print(verdict, opts)
      {:error, reason} -> ProdRpc.print_error(reason)
    end
  end
end

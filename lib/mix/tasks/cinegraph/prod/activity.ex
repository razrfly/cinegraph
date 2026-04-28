defmodule Mix.Tasks.Cinegraph.Prod.Activity do
  @moduledoc """
  Read the production "today's activity" / N-day sparkline data over SSH
  (#739 Phase C). Calls `Cinegraph.Health.Activity.recent/1` on the prod
  node and prints the result locally.

  ## Usage

      mix cinegraph.prod.activity              # 7 days (default)
      mix cinegraph.prod.activity --days 30    # 30 days
      mix cinegraph.prod.activity --json       # single-line JSON for piping

  Requires `REMOTE_APP_BIN` env var. See MAINTENANCE.md.
  """
  use Mix.Task

  @shortdoc "Read prod recent-activity / sparkline data"

  alias Cinegraph.ProdRpc

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [json: :boolean, days: :integer])
    # See prod/health.ex: skip app.start to keep stdout clean for jq.

    days =
      case Keyword.get(opts, :days, 7) do
        n when is_integer(n) and n > 0 -> n
        other -> Mix.raise("--days must be a positive integer, got: #{inspect(other)}")
      end

    expr = ~s|IO.puts(Jason.encode!(Cinegraph.Health.Activity.recent(#{days})))|

    case ProdRpc.eval_json(expr) do
      {:ok, activity} -> ProdRpc.print(activity, opts)
      {:error, reason} -> ProdRpc.print_error(reason)
    end
  end
end

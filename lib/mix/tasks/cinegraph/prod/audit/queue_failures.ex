defmodule Mix.Tasks.Cinegraph.Prod.Audit.QueueFailures do
  @moduledoc """
  Run the queue-failures audit against production via `kamal app exec`.
  Calls `Cinegraph.Health.QueueFailures.audit/1` inside the running prod
  container and prints the result locally.

  At least one of `--queue` or `--worker` is required.

  ## Usage

      mix cinegraph.prod.audit.queue_failures --queue omdb --days 1
      mix cinegraph.prod.audit.queue_failures --worker Cinegraph.Workers.TMDbDetailsWorker --json

  Requires the `kamal` CLI on PATH. See MAINTENANCE.md → "Audits & ad-hoc
  reports".
  """
  use Mix.Task

  @shortdoc "Audit Oban discards on production grouped by worker + pattern"

  alias Cinegraph.ProdRpc

  @impl Mix.Task
  def run(args) do
    {opts, _, invalid} =
      OptionParser.parse(args,
        strict: [json: :boolean, days: :integer, queue: :string, worker: :string]
      )

    raise_invalid_options!(invalid)
    # See prod/health.ex: skip app.start to keep stdout clean for jq.

    days =
      case Keyword.get(opts, :days, 7) do
        n when is_integer(n) and n > 0 -> n
        other -> Mix.raise("--days must be a positive integer, got: #{inspect(other)}")
      end

    queue = Keyword.get(opts, :queue)
    worker = Keyword.get(opts, :worker)

    if is_nil(queue) and is_nil(worker) do
      Mix.raise(
        "at least one of --queue or --worker is required " <>
          "(usage: mix cinegraph.prod.audit.queue_failures --queue X [--worker Y] [--days N] [--json])"
      )
    end

    expr =
      ~s|IO.puts(Jason.encode!(Cinegraph.Health.QueueFailures.audit(#{build_audit_opts(days, queue, worker)})))|

    case ProdRpc.eval_json(expr) do
      {:ok, audit} -> ProdRpc.print(audit, opts)
      {:error, reason} -> ProdRpc.print_error(reason)
    end
  end

  defp build_audit_opts(days, queue, worker) do
    parts =
      [
        "days: #{days}",
        queue && ~s|queue: "#{escape_string(queue)}"|,
        worker && ~s|worker: "#{escape_string(worker)}"|
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(", ")

    "[#{parts}]"
  end

  # Keep input simple — IMDb event IDs / queue names / worker module names
  # don't legitimately contain quotes or backslashes, but reject anything
  # that does so the eval expression stays safe.
  defp escape_string(s) do
    if String.contains?(s, ~s["]) or String.contains?(s, "\\") or String.contains?(s, "\n") do
      Mix.raise("invalid characters in --queue/--worker value: #{inspect(s)}")
    else
      s
    end
  end

  defp raise_invalid_options!([]), do: :ok

  defp raise_invalid_options!(invalid) do
    Mix.raise("invalid option(s): #{inspect(invalid)}")
  end
end

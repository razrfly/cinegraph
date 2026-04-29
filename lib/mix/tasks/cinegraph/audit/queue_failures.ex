defmodule Mix.Tasks.Cinegraph.Audit.QueueFailures do
  @moduledoc """
  Generic Oban discard analysis. Groups discarded jobs by worker and by
  error pattern, surfaces top error clusters with sample text. Reusable
  across queues/workers — first surfaced by an OMDb spike (#760), but
  applies to anything.

  At least one of `--queue` or `--worker` is required.

  ## Usage

      mix cinegraph.audit.queue_failures --queue omdb
      mix cinegraph.audit.queue_failures --queue scraping --days 1
      mix cinegraph.audit.queue_failures --worker Cinegraph.Workers.OmdbWorker --json
      mix cinegraph.audit.queue_failures --queue tmdb --worker Cinegraph.Workers.TMDbDetailsWorker

  See `mix cinegraph.prod.audit.queue_failures` for the production variant
  and `MAINTENANCE.md` → "Audits & ad-hoc reports".
  """
  use Mix.Task

  alias Cinegraph.Health.QueueFailures

  @shortdoc "Audit Oban discards grouped by worker + error pattern"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, invalid} =
      OptionParser.parse(args,
        strict: [json: :boolean, days: :integer, queue: :string, worker: :string]
      )

    raise_invalid_options!(invalid)

    json? = Keyword.get(opts, :json, false)

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
          "(usage: mix cinegraph.audit.queue_failures --queue X [--worker Y] [--days N] [--json])"
      )
    end

    audit_opts =
      [days: days, queue: queue, worker: worker]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    result = QueueFailures.audit(audit_opts)

    if json? do
      result
      |> Jason.encode!(pretty: true)
      |> IO.puts()
    else
      print_table(result)
    end
  end

  defp raise_invalid_options!([]), do: :ok

  defp raise_invalid_options!(invalid) do
    Mix.raise("invalid option(s): #{inspect(invalid)}")
  end

  defp print_table(%{
         generated_at: gen_at,
         window_days: days,
         filter: f,
         summary: s,
         top_errors: tops
       }) do
    filter_desc =
      [
        f.queue && "queue=#{f.queue}",
        f.worker && "worker=#{f.worker}"
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")

    Mix.shell().info("Queue-failures audit — last #{days} days, generated #{gen_at}")
    Mix.shell().info("filter: #{filter_desc}")
    Mix.shell().info("total_discarded: #{s.total_discarded}")
    Mix.shell().info("")

    if s.total_discarded == 0 do
      Mix.shell().info("(no discards in window)")
    else
      Mix.shell().info("=== by worker ===")

      s.by_worker
      |> Enum.sort_by(fn {_w, c} -> -c end)
      |> Enum.each(fn {w, c} ->
        Mix.shell().info("  #{String.pad_leading(Integer.to_string(c), 6)}  #{w}")
      end)

      Mix.shell().info("")
      Mix.shell().info("=== top error patterns ===")

      Mix.shell().info(
        String.pad_trailing("pattern", 20) <>
          String.pad_leading("count", 8) <>
          String.pad_leading("%", 8) <>
          "  sample_workers / sample_error (truncated)"
      )

      Mix.shell().info(String.duplicate("-", 110))

      Enum.each(tops, fn t ->
        workers_str = Enum.join(t.sample_workers, ", ")

        Mix.shell().info(
          String.pad_trailing(Atom.to_string(t.pattern), 20) <>
            String.pad_leading(Integer.to_string(t.count), 8) <>
            String.pad_leading(:erlang.float_to_binary(t.pct, decimals: 1), 8) <>
            "  " <> workers_str
        )

        if t.sample_error do
          Mix.shell().info("    " <> truncate(t.sample_error, 100))
        end
      end)
    end
  end

  defp truncate(s, n) when byte_size(s) <= n, do: s
  defp truncate(s, n), do: String.slice(s, 0, n - 1) <> "…"
end

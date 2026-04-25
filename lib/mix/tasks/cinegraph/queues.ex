defmodule Mix.Tasks.Cinegraph.Queues do
  @moduledoc """
  Snapshot of Oban queue state — what's pending, executing, retrying, failed.

  ## Usage

      mix cinegraph.queues
      mix cinegraph.queues --json

  ## Options

    * `--json` — emit JSON matching the `Cinegraph.Health.Queues.snapshot/1` contract.
  """
  use Mix.Task

  @shortdoc "Show Oban queue state"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} = OptionParser.parse(args, strict: [json: :boolean])
    json? = Keyword.get(opts, :json, false)

    snapshot = Cinegraph.Health.Queues.snapshot(bypass_cache: true)

    if json? do
      snapshot
      |> serialize()
      |> Jason.encode!(pretty: true)
      |> IO.puts()
    else
      print_table(snapshot)
    end
  end

  defp serialize(%{generated_at: ts, queues: queues, total_failures_last_hour: total}) do
    %{
      "generated_at" => DateTime.to_iso8601(ts),
      "total_failures_last_hour" => total,
      "queues" =>
        Enum.map(queues, fn q ->
          %{
            "name" => Atom.to_string(q.name),
            "available" => q.available,
            "executing" => q.executing,
            "scheduled" => q.scheduled,
            "retryable" => q.retryable,
            "discarded" => q.discarded,
            "cancelled" => q.cancelled,
            "failures_last_hour" => q.failures_last_hour,
            "longest_running_seconds" => q.longest_running_seconds
          }
        end)
    }
  end

  defp print_table(%{generated_at: ts, queues: queues, total_failures_last_hour: total}) do
    Mix.shell().info("Oban queue snapshot — #{DateTime.to_iso8601(ts)}")
    Mix.shell().info(String.duplicate("=", 92))

    Mix.shell().info(
      String.pad_trailing("queue", 22) <>
        String.pad_leading("avail", 8) <>
        String.pad_leading("exec", 8) <>
        String.pad_leading("sched", 8) <>
        String.pad_leading("retry", 8) <>
        String.pad_leading("disc", 8) <>
        String.pad_leading("canc", 8) <>
        String.pad_leading("fail/hr", 10) <>
        String.pad_leading("longest(s)", 12)
    )

    Mix.shell().info(String.duplicate("-", 92))

    Enum.each(queues, fn q ->
      Mix.shell().info(
        String.pad_trailing(Atom.to_string(q.name), 22) <>
          String.pad_leading(Integer.to_string(q.available), 8) <>
          String.pad_leading(Integer.to_string(q.executing), 8) <>
          String.pad_leading(Integer.to_string(q.scheduled), 8) <>
          String.pad_leading(Integer.to_string(q.retryable), 8) <>
          String.pad_leading(Integer.to_string(q.discarded), 8) <>
          String.pad_leading(Integer.to_string(q.cancelled), 8) <>
          String.pad_leading(Integer.to_string(q.failures_last_hour), 10) <>
          String.pad_leading(Integer.to_string(q.longest_running_seconds), 12)
      )
    end)

    Mix.shell().info(String.duplicate("=", 92))
    Mix.shell().info("Total failures in last hour: #{total}")
  end
end

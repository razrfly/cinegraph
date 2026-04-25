defmodule Mix.Tasks.Cinegraph.Status do
  @moduledoc """
  Quick operational status: today's activity, queue health, last sync timestamp.

  For drift/data-quality, see `mix cinegraph.health`.

  ## Usage

      mix cinegraph.status
      mix cinegraph.status --json
  """
  use Mix.Task

  alias Cinegraph.Health.Facade

  @shortdoc "Today's activity, queue state, last sync timestamp"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} = OptionParser.parse(args, strict: [json: :boolean])
    json? = Keyword.get(opts, :json, false)

    status = Facade.compute_status()

    if json? do
      status |> serialize() |> Jason.encode!(pretty: true) |> IO.puts()
    else
      print(status)
    end
  end

  defp serialize(status) do
    %{
      "generated_at" => DateTime.to_iso8601(status.generated_at),
      "last_sync_at" => format_dt(status.last_sync_at),
      "activity_today" => serialize_activity(status.activity_today),
      "queues" => serialize_queues(status.queues)
    }
  end

  defp serialize_activity(%{date: date} = activity) do
    activity
    |> Map.put(:date, Date.to_iso8601(date))
    |> Map.new(fn {k, v} -> {Atom.to_string(k), v} end)
  end

  defp serialize_queues(%{generated_at: ts, queues: queues, total_failures_last_hour: total}) do
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

  defp format_dt(nil), do: nil
  defp format_dt(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_dt(%NaiveDateTime{} = dt), do: NaiveDateTime.to_iso8601(dt)
  defp format_dt(other), do: to_string(other)

  defp print(status) do
    a = status.activity_today

    Mix.shell().info("Cinegraph operational status — #{DateTime.to_iso8601(status.generated_at)}")
    Mix.shell().info(String.duplicate("=", 70))
    Mix.shell().info("")
    Mix.shell().info("Last movie row updated: #{format_dt(status.last_sync_at) || "never"}")
    Mix.shell().info("")
    Mix.shell().info("Today (#{Date.to_iso8601(a.date)}):")
    Mix.shell().info("  movies added:        #{a.movies_added}")
    Mix.shell().info("  people added:        #{a.people_added}")
    Mix.shell().info("  ceremonies updated:  #{a.ceremonies_updated}")
    Mix.shell().info("  OMDb fetches:        #{a.omdb_fetches}")
    Mix.shell().info("  jobs completed:      #{a.jobs_completed}")
    Mix.shell().info("  jobs failed:         #{a.jobs_failed}")
    Mix.shell().info("")

    queues = status.queues.queues
    busy = Enum.filter(queues, &(&1.available + &1.executing + &1.retryable > 0))

    Mix.shell().info(
      "Queues: #{length(busy)}/#{length(queues)} active, #{status.queues.total_failures_last_hour} failures in last hour"
    )
  end
end

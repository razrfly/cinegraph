defmodule Mix.Tasks.Cinegraph.Activity do
  @moduledoc """
  Today's activity counters — movies/people/ceremonies added, OMDb fetches,
  Oban job completions and failures.

  ## Usage

      mix cinegraph.activity                # today
      mix cinegraph.activity --days 7       # last 7 UTC days, most recent first
      mix cinegraph.activity --json
  """
  use Mix.Task

  alias Cinegraph.Health.Activity

  @shortdoc "Show today's activity counters"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} = OptionParser.parse(args, strict: [json: :boolean, days: :integer])
    json? = Keyword.get(opts, :json, false)
    days = Keyword.get(opts, :days, 1)

    rows =
      if days == 1 do
        [Activity.today(bypass_cache: true)]
      else
        Activity.recent(days)
      end

    if json? do
      rows
      |> Enum.map(&serialize/1)
      |> Jason.encode!(pretty: true)
      |> IO.puts()
    else
      print_table(rows)
    end
  end

  defp serialize(%{date: date} = row) do
    row
    |> Map.put(:date, Date.to_iso8601(date))
    |> Map.new(fn {k, v} -> {Atom.to_string(k), v} end)
  end

  defp print_table(rows) do
    Mix.shell().info(
      String.pad_trailing("date", 12) <>
        String.pad_leading("movies+", 10) <>
        String.pad_leading("people+", 10) <>
        String.pad_leading("ceremons", 10) <>
        String.pad_leading("OMDb", 8) <>
        String.pad_leading("jobs✓", 12) <>
        String.pad_leading("jobs✗", 8)
    )

    Mix.shell().info(String.duplicate("-", 70))

    Enum.each(rows, fn r ->
      Mix.shell().info(
        String.pad_trailing(Date.to_iso8601(r.date), 12) <>
          String.pad_leading(Integer.to_string(r.movies_added), 10) <>
          String.pad_leading(Integer.to_string(r.people_added), 10) <>
          String.pad_leading(Integer.to_string(r.ceremonies_updated), 10) <>
          String.pad_leading(Integer.to_string(r.omdb_fetches), 8) <>
          String.pad_leading(Integer.to_string(r.jobs_completed), 12) <>
          String.pad_leading(Integer.to_string(r.jobs_failed), 8)
      )
    end)
  end
end

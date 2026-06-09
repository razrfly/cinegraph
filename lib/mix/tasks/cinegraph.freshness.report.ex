defmodule Mix.Tasks.Cinegraph.Freshness.Report do
  @moduledoc """
  Freshness rollup (#1096 Phase B / #1010 substrate) — one row per source over the
  `data_refreshes` ledger: tracked / fresh / stale / never-fetched / ineligible /
  errors / oldest fetch. The single query that answers "how fresh is everything?"

  ## Usage

      mix cinegraph.freshness.report          # print the table
      mix cinegraph.freshness.report --json   # machine-readable (ProdRpc / §7 check-in)
  """
  use Mix.Task

  alias Cinegraph.Freshness.Report

  @shortdoc "Per-source freshness rollup over data_refreshes (#1096 Phase B)"

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [json: :boolean])
    json? = Keyword.get(opts, :json, false)

    # Keep --json stdout clean (silence boot + Ecto logging before app.start).
    if json?, do: Logger.configure(level: :warning)

    Mix.Task.run("app.start")

    report = Report.report()

    if json? do
      report
      |> serialize()
      |> Jason.encode!(pretty: true)
      |> IO.puts()
    else
      print_table(report)
    end
  end

  defp serialize(report) do
    %{
      "generated_at" => DateTime.to_iso8601(report.generated_at),
      "sources" =>
        Enum.map(report.sources, fn r ->
          Map.new(r, fn {k, v} -> {to_string(k), stringify(v)} end)
        end)
    }
  end

  defp stringify(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp stringify(v), do: v

  defp print_table(report) do
    Mix.shell().info("Data freshness — #{DateTime.to_iso8601(report.generated_at)}")
    Mix.shell().info(String.duplicate("=", 100))

    Mix.shell().info(
      [
        pad("source", 18),
        pad("entity", 16),
        rpad("tracked", 10),
        rpad("fresh", 9),
        rpad("stale", 9),
        rpad("never", 9),
        rpad("inelig", 9),
        rpad("errors", 9),
        rpad("oldest", 12)
      ]
      |> Enum.join("")
    )

    Mix.shell().info(String.duplicate("-", 100))

    Enum.each(report.sources, fn r ->
      Mix.shell().info(
        [
          pad(r.source, 18),
          pad(r.entity_type, 16),
          rpad(num(r.tracked), 10),
          rpad(num(r.fresh), 9),
          rpad(num(r.stale), 9),
          rpad(num(r.never), 9),
          rpad(num(r.ineligible), 9),
          rpad(num(r.errors), 9),
          rpad(date(r.oldest_fetch), 12)
        ]
        |> Enum.join("")
      )
    end)
  end

  defp num(nil), do: "—"
  defp num(n) when is_integer(n), do: Integer.to_string(n)
  defp date(nil), do: "—"
  defp date(%DateTime{} = dt), do: Date.to_iso8601(DateTime.to_date(dt))
  defp pad(s, w), do: String.pad_trailing(to_string(s), w)
  defp rpad(s, w), do: String.pad_leading(to_string(s), w - 1) <> " "
end

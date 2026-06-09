defmodule Mix.Tasks.Cinegraph.SurfaceArea do
  @moduledoc """
  Data surface-area report (#1090 Phase 0) — one terminal-state coverage row per
  external source, the single number the surface-area tracker pings.

  ## Usage

      mix cinegraph.surface_area          # print the table
      mix cinegraph.surface_area --json   # machine-readable (for ProdRpc / the §7 check-in)

  Per fetchable source: eligible / fetched / source-absent / needs-fetch /
  materialization-debt / terminal%. Computed & supplemental sources are listed but
  carry no coverage number (they aren't a fetch backlog).
  """
  use Mix.Task

  alias Cinegraph.Health.SurfaceArea

  @shortdoc "Terminal-state coverage per external data source (#1090)"

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [json: :boolean])
    json? = Keyword.get(opts, :json, false)

    # Keep --json stdout clean — silence boot + Ecto query logging (set BEFORE app.start so
    # Honeybadger/AppSignal/Repo.Metrics boot lines don't land on stdout) so the only thing
    # printed is the JSON document. The clean prod path is ProdRpc → IO.puts(Jason), but this
    # keeps the local/`bin/cinegraph` --json parseable too.
    if json?, do: Logger.configure(level: :warning)

    Mix.Task.run("app.start")

    report = SurfaceArea.report()

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
        Enum.map(report.sources, fn r -> Map.new(r, fn {k, v} -> {to_string(k), v} end) end)
    }
  end

  defp print_table(report) do
    Mix.shell().info("Data surface area — #{DateTime.to_iso8601(report.generated_at)}")
    Mix.shell().info(String.duplicate("=", 96))

    Mix.shell().info(
      [
        pad("source", 22),
        rpad("eligible", 11),
        rpad("fetched", 11),
        rpad("absent", 9),
        rpad("needs", 9),
        rpad("debt", 8),
        rpad("terminal%", 10),
        rpad("target", 9)
      ]
      |> Enum.join("")
    )

    Mix.shell().info(String.duplicate("-", 96))

    Enum.each(report.sources, fn r ->
      Mix.shell().info(
        [
          pad(r.source, 22),
          rpad(num(r.eligible), 11),
          rpad(num(r.fetched), 11),
          rpad(num(r.source_absent), 9),
          rpad(num(r.needs_fetch), 9),
          rpad(num(r.materialization_debt), 8),
          rpad(pct(r.terminal_pct), 10),
          rpad(pct(r.target), 9)
        ]
        |> Enum.join("")
      )

      if r.note, do: Mix.shell().info("    └ #{r.note}")
    end)
  end

  defp num(nil), do: "—"
  defp num(n) when is_integer(n), do: Integer.to_string(n)
  defp pct(nil), do: "—"
  defp pct(f) when is_float(f), do: "#{f}%"
  defp pad(s, w), do: String.pad_trailing(to_string(s), w)
  defp rpad(s, w), do: String.pad_leading(to_string(s), w - 1) <> " "
end

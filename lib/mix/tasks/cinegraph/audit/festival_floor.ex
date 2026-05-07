defmodule Mix.Tasks.Cinegraph.Audit.FestivalFloor do
  @moduledoc """
  Audit ceremonies whose nomination count is below the per-organization
  floor (50% of the org's median ceremony) — the `nominations_below_floor`
  drift signal in #722, surfaced for triage in #896 Phase 2.1.

  ## Usage

      mix cinegraph.audit.festival_floor              # grouped text table
      mix cinegraph.audit.festival_floor --json       # machine-readable
      mix cinegraph.audit.festival_floor --org AMPAS  # one organization
  """
  use Mix.Task

  alias Cinegraph.Health.FestivalFloorAudit

  @shortdoc "Audit ceremonies below the per-organization nomination floor"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} =
      OptionParser.parse(args, strict: [json: :boolean, org: :string])

    audit_opts = if opts[:org], do: [org: opts[:org]], else: []
    result = FestivalFloorAudit.audit(audit_opts)

    if Keyword.get(opts, :json, false) do
      result |> Jason.encode!(pretty: true) |> IO.puts()
    else
      print_text(result)
    end
  end

  defp print_text([]) do
    Mix.shell().info("No below-floor ceremonies. ✓")
  end

  defp print_text(orgs) do
    total = Enum.reduce(orgs, 0, &(&1.below_floor_count + &2))
    Mix.shell().info("Below-floor ceremonies (#{total} across #{length(orgs)} orgs)")
    Mix.shell().info("")

    Enum.each(orgs, &print_org/1)
  end

  defp print_org(%{
         organization: org,
         ceremonies: ceremonies,
         median: median,
         below_floor_count: count
       }) do
    label =
      [org.abbreviation, org.name]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.uniq()
      |> Enum.join(" · ")

    Mix.shell().info("#{label} (org median #{format_num(median)}, #{count} below)")

    Enum.each(ceremonies, fn c ->
      Mix.shell().info("  #{c.year}  noms=#{c.nominations}  delta #{format_delta(c.delta_pct)}")
    end)

    Mix.shell().info("")
  end

  defp format_num(nil), do: "?"
  defp format_num(n) when is_float(n), do: :erlang.float_to_binary(n, decimals: 1)
  defp format_num(n), do: to_string(n)

  defp format_delta(nil), do: "?"
  defp format_delta(d) when is_float(d), do: "#{:erlang.float_to_binary(d, decimals: 1)}%"
  defp format_delta(d), do: "#{d}%"
end

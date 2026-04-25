defmodule Mix.Tasks.Cinegraph.Health do
  @moduledoc """
  Overall health verdict — runs all 4 drift domains and rolls them up
  to green/amber/red.

  ## Usage

      mix cinegraph.health
      mix cinegraph.health --json
      mix cinegraph.health --domain people
  """
  use Mix.Task

  alias Cinegraph.Health.Facade

  @shortdoc "Overall health verdict (rollup of all drift domains)"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} =
      OptionParser.parse(args, strict: [json: :boolean, domain: :string])

    json? = Keyword.get(opts, :json, false)
    raw_domain = Keyword.get(opts, :domain)

    only_domain =
      case normalize_domain(raw_domain) do
        {:ok, d} ->
          d

        :none ->
          nil

        {:error, msg} ->
          Mix.shell().error("✗ #{msg}")
          System.halt(1)
      end

    verdict = Facade.compute_full_verdict()

    rendered =
      if only_domain do
        case Map.get(verdict.domains, only_domain) do
          nil ->
            Mix.shell().error("✗ unknown domain '#{raw_domain}'")
            System.halt(1)

          domain_data ->
            verdict
            |> Map.put(:domains, %{only_domain => domain_data})
            |> Map.put(:status, domain_data.status)
        end
      else
        verdict
      end

    if json? do
      rendered |> serialize() |> Jason.encode!(pretty: true) |> IO.puts()
    else
      print_summary(rendered)
    end
  end

  defp normalize_domain(nil), do: :none
  defp normalize_domain("people"), do: {:ok, :people}
  defp normalize_domain("movies"), do: {:ok, :movies}
  defp normalize_domain("festivals"), do: {:ok, :festivals}
  defp normalize_domain("ratings"), do: {:ok, :ratings}

  defp normalize_domain(other) do
    {:error,
     "invalid domain: #{inspect(other)}. valid domains: people, movies, festivals, ratings"}
  end

  defp serialize(verdict) do
    %{
      "generated_at" => DateTime.to_iso8601(verdict.generated_at),
      "status" => Atom.to_string(verdict.status),
      "worst_check" => serialize_check(verdict.worst_check),
      "domains" =>
        Enum.into(verdict.domains, %{}, fn {domain, %{status: status, checks: checks}} ->
          {Atom.to_string(domain),
           %{
             "status" => Atom.to_string(status),
             "checks" => Enum.map(checks, &serialize_check/1)
           }}
        end)
    }
  end

  defp serialize_check(nil), do: nil

  defp serialize_check(check) do
    %{
      "domain" => Atom.to_string(check.domain),
      "check" => Atom.to_string(check.check),
      "status" => Atom.to_string(check.status),
      "total_population" => check.total_population,
      "affected_count" => check.affected_count,
      "affected_pct" => check.affected_pct,
      "blocked_reason" => check.blocked_reason
    }
  end

  defp print_summary(verdict) do
    color = status_label(verdict.status)
    Mix.shell().info("Health verdict: #{color}")
    Mix.shell().info("Generated: #{DateTime.to_iso8601(verdict.generated_at)}")
    Mix.shell().info("")

    Enum.each(verdict.domains, fn {domain, %{status: status, checks: checks}} ->
      Mix.shell().info("[#{status_label(status)}] #{domain}")

      Enum.each(checks, fn c ->
        Mix.shell().info(
          "  " <>
            String.pad_trailing(Atom.to_string(c.check), 44) <>
            String.pad_leading("#{c.affected_count}", 12) <>
            String.pad_leading("#{c.affected_pct}%", 9) <>
            "  " <> status_label(c.status)
        )
      end)

      Mix.shell().info("")
    end)

    if verdict.worst_check do
      w = verdict.worst_check

      Mix.shell().info(
        "Worst: #{w.domain}/#{w.check} → #{status_label(w.status)} (#{w.affected_pct}%)"
      )
    end
  end

  defp status_label(:green), do: "GREEN"
  defp status_label(:amber), do: "AMBER"
  defp status_label(:red), do: "RED"
  defp status_label(:unknown), do: "UNKNOWN"
  defp status_label(other), do: inspect(other)
end

defmodule Mix.Tasks.Cinegraph.Prod.Drift do
  @moduledoc """
  Run drift checks against production via `kamal app exec`. Mirror of
  `mix cinegraph.drift <domain>` — same domains, same options, same
  output. Calls `Cinegraph.Health.Drift.<Domain>.all/1` inside the
  running prod container.

  ## Usage

      mix cinegraph.prod.drift people    [--json] [--limit N]
      mix cinegraph.prod.drift movies    [--json] [--limit N] [--year YYYY]
      mix cinegraph.prod.drift festivals [--json] [--limit N] [--org SLUG]
      mix cinegraph.prod.drift ratings   [--json] [--limit N]

  Requires the `kamal` CLI on PATH. See MAINTENANCE.md → "Audits & ad-hoc
  reports".
  """
  use Mix.Task

  @shortdoc "Run prod drift checks for a given domain"

  alias Cinegraph.ProdRpc

  # Same per-domain whitelist as `Mix.Tasks.Cinegraph.Drift`. Duplicated
  # rather than shared because the local task lives outside the runtime
  # boot path and we don't want `app.start` here.
  @domain_options %{
    "people" => {"Cinegraph.Health.Drift.People", [:limit]},
    "movies" => {"Cinegraph.Health.Drift.Movies", [:limit, :year]},
    "festivals" => {"Cinegraph.Health.Drift.Festivals", [:limit, :org]},
    "ratings" => {"Cinegraph.Health.Drift.Ratings", [:limit]}
  }

  @impl Mix.Task
  def run([]), do: usage_error("missing domain")

  def run([domain | rest]) do
    {opts, _, invalid} =
      OptionParser.parse(rest,
        strict: [json: :boolean, limit: :integer, year: :integer, org: :string]
      )

    reject_invalid_switches!(invalid)

    {module, allowed} =
      case Map.fetch(@domain_options, domain) do
        {:ok, v} -> v
        :error -> usage_error("unknown domain '#{domain}' — try people|movies|festivals|ratings")
      end

    runner_opts = Keyword.drop(opts, [:json])
    validate_opts!(runner_opts, domain, allowed)

    expr = ~s|IO.puts(Jason.encode!(#{module}.all(#{build_opts_kw(runner_opts)})))|

    case ProdRpc.eval_json(expr) do
      {:ok, drift} -> ProdRpc.print(drift, opts)
      {:error, reason} -> ProdRpc.print_error(reason)
    end
  end

  defp build_opts_kw(opts) do
    parts =
      opts
      |> Enum.map(fn
        {:limit, n} when is_integer(n) -> "limit: #{n}"
        {:year, n} when is_integer(n) -> "year: #{n}"
        {:org, s} when is_binary(s) -> ~s|org: "#{escape_string(s)}"|
      end)
      |> Enum.join(", ")

    "[#{parts}]"
  end

  defp escape_string(s) do
    if String.contains?(s, ~s["]) or String.contains?(s, "\\") or String.contains?(s, "\n") do
      Mix.raise("invalid characters in option value: #{inspect(s)}")
    else
      s
    end
  end

  defp reject_invalid_switches!([]), do: :ok

  defp reject_invalid_switches!(invalid) do
    flags = invalid |> Enum.map(fn {flag, _} -> flag end) |> Enum.join(", ")
    usage_error("unknown flag(s): #{flags}")
  end

  defp validate_opts!(opts, domain, allowed) do
    unknown = Keyword.keys(opts) -- allowed

    case unknown do
      [] ->
        :ok

      keys ->
        flags = keys |> Enum.map(&"--#{&1}") |> Enum.join(", ")
        allowed_flags = allowed |> Enum.map(&"--#{&1}") |> Enum.join(", ")
        usage_error("domain '#{domain}' does not support #{flags}; allowed: #{allowed_flags}")
    end
  end

  defp usage_error(msg) do
    Mix.shell().error("✗ #{msg}")
    Mix.shell().info("\nUsage:")
    Mix.shell().info("  mix cinegraph.prod.drift people    [--json] [--limit N]")
    Mix.shell().info("  mix cinegraph.prod.drift movies    [--json] [--limit N] [--year YYYY]")
    Mix.shell().info("  mix cinegraph.prod.drift festivals [--json] [--limit N] [--org SLUG]")
    Mix.shell().info("  mix cinegraph.prod.drift ratings   [--json] [--limit N]")
    System.halt(1)
  end
end

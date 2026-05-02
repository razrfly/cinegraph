defmodule Mix.Tasks.Cinegraph.Prod.Audit.Availability do
  @moduledoc """
  Run the watch availability audit against production via `kamal app exec`.

  ## Usage

      mix cinegraph.prod.audit.availability
      mix cinegraph.prod.audit.availability --json
      mix cinegraph.prod.audit.availability --limit 25 --region PL --stale-days 14
  """
  use Mix.Task

  alias Cinegraph.ProdRpc

  @shortdoc "Audit production watch availability coverage and freshness"

  @impl Mix.Task
  def run(args) do
    {opts, _, invalid} =
      OptionParser.parse(args,
        strict: [
          json: :boolean,
          limit: :integer,
          region: :string,
          stale_days: :integer,
          "stale-days": :integer
        ]
      )

    raise_invalid_options!(invalid)

    expr = build_expression(opts)

    case ProdRpc.eval_json(expr) do
      {:ok, audit} -> ProdRpc.print(audit, opts)
      {:error, reason} -> ProdRpc.print_error(reason)
    end
  end

  @doc false
  def build_expression(opts) do
    ~s|IO.puts(Jason.encode!(Cinegraph.Health.AvailabilityAudit.audit(#{build_opts_kw(opts)})))|
  end

  defp build_opts_kw(opts) do
    parts =
      opts
      |> Keyword.drop([:json])
      |> normalize_stale_days()
      |> Enum.map(fn
        {:limit, n} when is_integer(n) -> "limit: #{n}"
        {:region, region} when is_binary(region) -> "region: #{inspect(region)}"
        {:stale_days, n} when is_integer(n) -> "stale_days: #{n}"
      end)
      |> Enum.join(", ")

    "[#{parts}]"
  end

  defp normalize_stale_days(opts) do
    case Keyword.pop(opts, :"stale-days") do
      {nil, opts} -> opts
      {value, opts} -> Keyword.put(opts, :stale_days, value)
    end
  end

  defp raise_invalid_options!([]), do: :ok
  defp raise_invalid_options!(invalid), do: Mix.raise("invalid option(s): #{inspect(invalid)}")
end

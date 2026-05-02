defmodule Mix.Tasks.Cinegraph.Prod.Audit.CanonicalLists do
  @moduledoc """
  Run the canonical-lists audit against production via `kamal app exec`.

  ## Usage

      mix cinegraph.prod.audit.canonical_lists
      mix cinegraph.prod.audit.canonical_lists --json
      mix cinegraph.prod.audit.canonical_lists --blank-only
      mix cinegraph.prod.audit.canonical_lists --stale-days 90
  """
  use Mix.Task

  alias Cinegraph.ProdRpc

  @shortdoc "Audit production canonical IMDb list freshness and coverage"

  @impl Mix.Task
  def run(args) do
    {opts, _, invalid} =
      OptionParser.parse(args,
        strict: [
          json: :boolean,
          blank_only: :boolean,
          "blank-only": :boolean,
          stale_days: :integer,
          "stale-days": :integer
        ]
      )

    raise_invalid_options!(invalid)

    case ProdRpc.eval_json(build_expression(opts)) do
      {:ok, audit} -> ProdRpc.print(audit, opts)
      {:error, reason} -> ProdRpc.print_error(reason)
    end
  end

  @doc false
  def build_expression(opts) do
    opts = Mix.Tasks.Cinegraph.Audit.CanonicalLists.audit_opts(opts)
    ~s|IO.puts(Jason.encode!(Cinegraph.Health.CanonicalListsAudit.audit(#{build_opts_kw(opts)})))|
  end

  defp build_opts_kw(opts) do
    opts
    |> Enum.map(fn
      {:blank_only, value} when is_boolean(value) -> "blank_only: #{value}"
      {:stale_days, value} when is_integer(value) -> "stale_days: #{value}"
    end)
    |> Enum.join(", ")
    |> then(&"[#{&1}]")
  end

  defp raise_invalid_options!([]), do: :ok
  defp raise_invalid_options!(invalid), do: Mix.raise("invalid option(s): #{inspect(invalid)}")
end

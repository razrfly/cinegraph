defmodule Mix.Tasks.Cinegraph.Prod.Audit.ImdbListIntegrity do
  @moduledoc """
  Run the stored IMDb list integrity audit against production via `kamal app exec`.

  ## Usage

      mix cinegraph.prod.audit.imdb_list_integrity
      mix cinegraph.prod.audit.imdb_list_integrity --json
  """
  use Mix.Task

  alias Cinegraph.ProdRpc

  @shortdoc "Audit production stored IMDb list membership integrity"

  @doc false
  @impl Mix.Task
  def run(args) do
    {opts, _, invalid} = Mix.Tasks.Cinegraph.Audit.ImdbListIntegrity.parse_args(args)
    raise_invalid_options!(invalid)

    case ProdRpc.eval_json(build_expression(opts)) do
      {:ok, audit} -> ProdRpc.print(audit, opts)
      {:error, reason} -> ProdRpc.print_error(reason)
    end
  end

  @doc false
  def build_expression(_opts \\ []) do
    ~s|IO.puts(Jason.encode!(Cinegraph.Health.ImdbListIntegrityAudit.audit()))|
  end

  defp raise_invalid_options!([]), do: :ok
  defp raise_invalid_options!(invalid), do: Mix.raise("invalid option(s): #{inspect(invalid)}")
end

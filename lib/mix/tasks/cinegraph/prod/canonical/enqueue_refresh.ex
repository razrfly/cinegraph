defmodule Mix.Tasks.Cinegraph.Prod.Canonical.EnqueueRefresh do
  @moduledoc """
  Enqueue production canonical IMDb list refreshes via `kamal app exec`.
  """
  use Mix.Task

  alias Cinegraph.ProdRpc

  @shortdoc "Enqueue production canonical IMDb list refresh jobs"

  @doc false
  @impl Mix.Task
  def run(args) do
    {opts, _, invalid} =
      OptionParser.parse(args, strict: Mix.Tasks.Cinegraph.Canonical.EnqueueRefresh.option_spec())

    raise_invalid_options!(invalid)

    case ProdRpc.eval_json(build_expression(opts)) do
      {:ok, %{"__error__" => reason}} -> ProdRpc.print_error({:eval_failed, reason})
      {:ok, result} -> ProdRpc.print(result, opts)
      {:error, reason} -> ProdRpc.print_error(reason)
    end
  end

  @doc false
  def build_expression(opts) do
    opts = Mix.Tasks.Cinegraph.Canonical.EnqueueRefresh.refresh_opts(opts)

    ~s|case Cinegraph.Maintenance.RefreshCanonicalLists.run(#{build_opts_kw(opts)}) do
  {:ok, stats} -> IO.puts(Jason.encode!(stats))
  {:error, reason} -> IO.puts(Jason.encode!(%{__error__: inspect(reason)}))
end|
  end

  defp build_opts_kw(opts) do
    opts
    |> Enum.map(fn
      {:list, value} when is_binary(value) -> "list: #{inspect(value)}"
      {:blank_only, value} when is_boolean(value) -> "blank_only: #{value}"
      {:stale_days, value} when is_integer(value) -> "stale_days: #{value}"
      {:limit, value} when is_integer(value) -> "limit: #{value}"
      {:all, value} when is_boolean(value) -> "all: #{value}"
      {:dry_run, value} when is_boolean(value) -> "dry_run: #{value}"
    end)
    |> Enum.join(", ")
    |> then(&"[#{&1}]")
  end

  defp raise_invalid_options!([]), do: :ok
  defp raise_invalid_options!(invalid), do: Mix.raise("invalid option(s): #{inspect(invalid)}")
end

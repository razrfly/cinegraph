defmodule Mix.Tasks.Cinegraph.Prod.Audit.ImdbListPagination do
  @moduledoc """
  Run the IMDb list pagination audit against production via `kamal app exec`.

  ## Usage

      mix cinegraph.prod.audit.imdb_list_pagination --list cult_movies_400 --json
      mix cinegraph.prod.audit.imdb_list_pagination --list-id ls053182933 --starts 1,76,151 --json
  """
  use Mix.Task

  alias Cinegraph.ProdRpc

  @shortdoc "Audit production IMDb list pagination windows"

  @doc false
  @impl Mix.Task
  def run(args) do
    {opts, _, invalid} = Mix.Tasks.Cinegraph.Audit.ImdbListPagination.parse_args(args)
    raise_invalid_options!(invalid)

    case ProdRpc.eval_json(build_expression(opts)) do
      {:ok, audit} -> ProdRpc.print(audit, opts)
      {:error, reason} -> ProdRpc.print_error(reason)
    end
  end

  @doc false
  def build_expression(opts) do
    opts = Mix.Tasks.Cinegraph.Audit.ImdbListPagination.audit_opts(opts)

    ~s|IO.puts(Jason.encode!(Cinegraph.Health.ImdbListPaginationAudit.audit(#{build_opts_kw(opts)})))|
  end

  defp build_opts_kw(opts) do
    opts
    |> Enum.map(fn
      {:list, value} when is_binary(value) -> "list: #{inspect(value)}"
      {:list_id, value} when is_binary(value) -> "list_id: #{inspect(value)}"
      {:starts, value} when is_binary(value) -> "starts: #{inspect(value)}"
      {:page_wait, value} when is_integer(value) -> "page_wait: #{value}"
      {:ajax_wait, value} when is_boolean(value) -> "ajax_wait: #{value}"
      {:scroll, value} when is_boolean(value) -> "scroll: #{value}"
      {:scroll_interval, value} when is_integer(value) -> "scroll_interval: #{value}"
    end)
    |> Enum.join(", ")
    |> then(&"[#{&1}]")
  end

  defp raise_invalid_options!([]), do: :ok
  defp raise_invalid_options!(invalid), do: Mix.raise("invalid option(s): #{inspect(invalid)}")
end

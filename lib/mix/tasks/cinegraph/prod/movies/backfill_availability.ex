defmodule Mix.Tasks.Cinegraph.Prod.Movies.BackfillAvailability do
  @moduledoc """
  Backfill production watch availability from stored TMDb JSON via ProdRpc.

  ## Usage

      mix cinegraph.prod.movies.backfill_availability --dry-run --json
      mix cinegraph.prod.movies.backfill_availability --dry-run --limit 100
      mix cinegraph.prod.movies.backfill_availability --limit 100 --after-id 500000 --batch-size 1000
      mix cinegraph.prod.movies.backfill_availability --regions US,GB --dry-run
  """
  use Mix.Task

  alias Cinegraph.ProdRpc

  @shortdoc "Backfill production watch availability from stored TMDb JSON"

  @doc false
  @impl Mix.Task
  def run(args) do
    {opts, _, invalid} =
      OptionParser.parse(args,
        strict: [
          json: :boolean,
          dry_run: :boolean,
          "dry-run": :boolean,
          limit: :integer,
          after_id: :integer,
          "after-id": :integer,
          batch_size: :integer,
          "batch-size": :integer,
          regions: :string
        ]
      )

    raise_invalid_options!(invalid)

    expr = build_expression(opts)

    case ProdRpc.eval_json(expr) do
      {:ok, %{"__error__" => reason}} -> ProdRpc.print_error({:eval_failed, reason})
      {:ok, stats} -> ProdRpc.print(stats, opts)
      {:error, reason} -> ProdRpc.print_error(reason)
    end
  end

  @doc false
  def build_expression(opts) do
    ~s|case Cinegraph.Movies.AvailabilityBackfill.run(#{build_opts_kw(opts)}) do
  {:ok, stats} -> IO.puts(Jason.encode!(stats))
  {:error, reason} -> IO.puts(Jason.encode!(%{__error__: inspect(reason)}))
end|
  end

  defp build_opts_kw(opts) do
    opts = normalize_aliases(opts)

    parts =
      [
        opt_integer(opts, :limit),
        opt_integer(opts, :after_id),
        opt_integer(opts, :batch_size),
        opt_regions(opts),
        opt_dry_run(opts)
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(", ")

    "[#{parts}]"
  end

  defp normalize_aliases(opts) do
    opts
    |> normalize_alias(:"dry-run", :dry_run)
    |> normalize_alias(:"after-id", :after_id)
    |> normalize_alias(:"batch-size", :batch_size)
    |> Keyword.drop([:json])
  end

  defp normalize_alias(opts, from, to) do
    case Keyword.pop(opts, from) do
      {nil, opts} -> opts
      {value, opts} -> Keyword.put(opts, to, value)
    end
  end

  defp opt_integer(opts, key) do
    case Keyword.get(opts, key) do
      value when is_integer(value) -> "#{key}: #{value}"
      _ -> nil
    end
  end

  defp opt_regions(opts) do
    case Keyword.get(opts, :regions) do
      value when is_binary(value) -> "regions: #{inspect(value)}"
      _ -> "regions: Cinegraph.Movies.Availability.configured_regions()"
    end
  end

  defp opt_dry_run(opts) do
    if Keyword.get(opts, :dry_run, false), do: "dry_run: true", else: nil
  end

  defp raise_invalid_options!([]), do: :ok
  defp raise_invalid_options!(invalid), do: Mix.raise("invalid option(s): #{inspect(invalid)}")
end

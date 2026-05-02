defmodule Mix.Tasks.Cinegraph.Canonical.EnqueueRefresh do
  @moduledoc """
  Enqueue background refreshes for canonical IMDb movie lists.

  ## Usage

      mix cinegraph.canonical.enqueue_refresh --list afi_100
      mix cinegraph.canonical.enqueue_refresh --blank-only --limit 10
      mix cinegraph.canonical.enqueue_refresh --stale-days 90 --limit 10
      mix cinegraph.canonical.enqueue_refresh --all --dry-run
  """
  use Mix.Task

  alias Cinegraph.Maintenance.RefreshCanonicalLists

  @shortdoc "Enqueue canonical IMDb list refresh jobs"

  @doc false
  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, invalid} = OptionParser.parse(args, strict: option_spec())
    raise_invalid_options!(invalid)
    refresh_opts = refresh_opts(opts)

    case RefreshCanonicalLists.run(refresh_opts) do
      {:ok, result} -> print_result(result)
    end
  end

  @doc false
  def option_spec do
    [
      list: :string,
      blank_only: :boolean,
      "blank-only": :boolean,
      stale_days: :integer,
      "stale-days": :integer,
      limit: :integer,
      all: :boolean,
      dry_run: :boolean,
      "dry-run": :boolean
    ]
  end

  @doc false
  def refresh_opts(opts) do
    opts
    |> normalize_alias(:"blank-only", :blank_only)
    |> normalize_alias(:"stale-days", :stale_days)
    |> normalize_alias(:"dry-run", :dry_run)
    |> Keyword.take([:list, :blank_only, :stale_days, :limit, :all, :dry_run])
  end

  defp print_result(result) do
    Mix.shell().info(
      "Canonical refresh: found=#{result.found} enqueued=#{result.enqueued} " <>
        "already=#{result.already_queued} failed=#{result.failed} dry_run=#{result.dry_run}"
    )

    if result.lists != [] do
      Mix.shell().info("lists: #{Enum.join(result.lists, ", ")}")
    end
  end

  defp normalize_alias(opts, from, to) do
    case Keyword.pop(opts, from) do
      {nil, opts} -> opts
      {value, opts} -> Keyword.put(opts, to, value)
    end
  end

  defp raise_invalid_options!([]), do: :ok
  defp raise_invalid_options!(invalid), do: Mix.raise("invalid option(s): #{inspect(invalid)}")
end

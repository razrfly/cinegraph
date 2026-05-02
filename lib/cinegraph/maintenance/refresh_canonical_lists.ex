defmodule Cinegraph.Maintenance.RefreshCanonicalLists do
  @moduledoc """
  Release-safe maintenance entry point for refreshing database-managed
  canonical IMDb lists.
  """

  alias Cinegraph.Health.CanonicalListsAudit
  alias Cinegraph.Workers.CanonicalImportOrchestrator

  require Logger

  @default_stale_days 90
  @default_trigger "manual_canonical_refresh"

  @doc """
  Select canonical IMDb lists and enqueue orchestrator jobs.

  Options:
    * `:list` - a single source_key
    * `:blank_only` - include blank lists
    * `:stale_days` - include lists stale by this many days
    * `:all` - include all active IMDb lists
    * `:limit` - positive integer cap
    * `:dry_run` - report only
    * `:trigger` - string stored in job args
  """
  def run(opts \\ []) when is_list(opts) do
    validate_selector!(opts)

    stale_days = Keyword.get(opts, :stale_days, @default_stale_days)
    audit = CanonicalListsAudit.audit(stale_days: stale_days)

    lists =
      audit.lists
      |> select_lists(opts)
      |> apply_limit(Keyword.get(opts, :limit))

    dry_run? = Keyword.get(opts, :dry_run, false)

    if dry_run? do
      {:ok, result(lists, 0, 0, 0, true)}
    else
      {enqueued, already, failed} =
        enqueue_each(lists, Keyword.get(opts, :trigger, @default_trigger))

      {:ok, result(lists, enqueued, already, failed, false)}
    end
  end

  defp validate_selector!(opts) do
    if Keyword.get(opts, :list) || Keyword.get(opts, :blank_only) ||
         Keyword.get(opts, :stale_days) || Keyword.get(opts, :all) do
      :ok
    else
      raise ArgumentError,
            "provide one selector: :list, :blank_only, :stale_days, or :all"
    end
  end

  defp select_lists(rows, opts) do
    cond do
      list_key = Keyword.get(opts, :list) ->
        Enum.filter(rows, &(&1.source_type == "imdb" and &1.source_key == list_key))

      Keyword.get(opts, :all, false) ->
        Enum.filter(rows, &(&1.source_type == "imdb"))

      true ->
        Enum.filter(rows, fn row ->
          row.source_type == "imdb" and
            ((Keyword.get(opts, :blank_only, false) and row.blank) or
               (Keyword.get(opts, :stale_days) && row.stale))
        end)
    end
  end

  defp apply_limit(rows, nil), do: rows

  defp apply_limit(rows, n) when is_integer(n) and n > 0, do: Enum.take(rows, n)

  defp apply_limit(_rows, other) do
    raise ArgumentError, ":limit must be a positive integer or nil, got: #{inspect(other)}"
  end

  defp enqueue_each(lists, trigger) do
    Enum.reduce(lists, {0, 0, 0}, fn list, {ok, already, failed} ->
      args = %{
        "action" => "orchestrate_import",
        "list_key" => list.source_key,
        "trigger" => trigger
      }

      case CanonicalImportOrchestrator.new(args) |> Oban.insert() do
        {:ok, %Oban.Job{conflict?: true}} ->
          {ok, already + 1, failed}

        {:ok, _job} ->
          {ok + 1, already, failed}

        {:error, reason} ->
          Logger.error(
            "RefreshCanonicalLists: failed to enqueue #{list.source_key}: #{inspect(reason)}"
          )

          {ok, already, failed + 1}
      end
    end)
  end

  defp result(lists, enqueued, already, failed, dry_run?) do
    %{
      found: length(lists),
      enqueued: enqueued,
      already_queued: already,
      failed: failed,
      dry_run: dry_run?,
      lists: Enum.map(lists, & &1.source_key)
    }
  end
end

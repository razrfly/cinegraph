defmodule Cinegraph.Database.Utils do
  @moduledoc """
  Shared database catalog helpers.
  """

  require Logger

  alias Cinegraph.Repo

  @doc """
  Returns true when a public relation has a qualifying unique index.

  PostgreSQL requires a valid, ready, non-partial unique index without
  expression columns before `REFRESH MATERIALIZED VIEW CONCURRENTLY` can run.
  """
  def has_unique_index?(relation_name) do
    case Repo.query(unique_index_query(), [relation_name]) do
      {:ok, %{rows: [[exists]]}} ->
        exists

      {:error, reason} ->
        Logger.warning(
          "has_unique_index? query failed for #{inspect(relation_name)}: #{inspect(reason)}"
        )

        false

      _ ->
        false
    end
  end

  defp unique_index_query do
    """
    SELECT EXISTS(
      SELECT 1
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
      JOIN pg_index i ON i.indrelid = c.oid
      WHERE n.nspname = 'public'
        AND c.relname = $1
        AND i.indisunique
        AND i.indisvalid
        AND i.indisready
        AND i.indpred IS NULL
        AND NOT EXISTS (
          SELECT 1
          FROM unnest(i.indkey) AS key(attnum)
          WHERE key.attnum = 0
        )
    )
    """
  end
end

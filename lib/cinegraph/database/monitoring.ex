defmodule Cinegraph.Database.Monitoring do
  @moduledoc """
  Read-only Postgres health probes for the shared-instance setup (#1018 / #1019).

  `long_running_queries/1` would have surfaced the #1019 incident (a 19.5 h
  `REFRESH`) within minutes. `connection_counts/0` shows the per-database backend
  usage that saturates the shared 100-connection ceiling.

  These are building blocks for alerting (wired under #1018) and are handy live
  from `iex` / `bin/cinegraph eval` during an incident.
  """

  alias Cinegraph.Repo

  @doc """
  Active queries running longer than `min_seconds` (default 300), oldest first.

  Excludes this probe's own backend. Returns a list of maps with `:pid`,
  `:datname`, `:usename`, `:state`, `:duration_s`, `:query`.
  """
  def long_running_queries(min_seconds \\ 300) when is_integer(min_seconds) do
    query!(
      """
      SELECT pid,
             datname,
             usename,
             state,
             EXTRACT(EPOCH FROM (now() - query_start))::int AS duration_s,
             left(query, 200) AS query
      FROM pg_stat_activity
      WHERE state = 'active'
        AND pid <> pg_backend_pid()
        AND query_start < now() - make_interval(secs => $1)
      ORDER BY query_start ASC
      """,
      [min_seconds]
    )
  end

  @doc "Backend counts grouped by database and state (saturation view)."
  def connection_counts do
    query!(
      """
      SELECT datname, state, count(*)::int AS count
      FROM pg_stat_activity
      WHERE datname IS NOT NULL
      GROUP BY datname, state
      ORDER BY datname, count DESC
      """,
      []
    )
  end

  defp query!(sql, params) do
    %{rows: rows, columns: cols} = Repo.query!(sql, params)
    # Atom keys to match the documented contract. Safe here: column names come
    # from our own fixed SELECT aliases, not from user input.
    keys = Enum.map(cols, &String.to_atom/1)
    Enum.map(rows, fn row -> keys |> Enum.zip(row) |> Map.new() end)
  end
end

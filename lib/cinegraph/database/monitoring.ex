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

  @doc "Configured `max_connections` (the hard ceiling, currently 300)."
  def max_connections do
    %{rows: [[n]]} =
      Repo.query!("SELECT setting::int FROM pg_settings WHERE name = 'max_connections'", [])

    n
  end

  @warn_pct 70
  @crit_pct 90

  @doc """
  One-shot connection-health snapshot over `pg_stat_activity` (#1018 monitoring).

  Returns a map with `:total_backends`, `:max_connections`, `:usage_pct`,
  `:by_database` (`[%{datname:, count:}]`), `:long_running`, `:status`
  (`:ok | :warn | :crit`), and human-readable `:warnings`.

  Note: PgBouncer's `cl_waiting` is not included — its admin console isn't
  app-queryable. Because cinegraph connects only via PgBouncer, its per-db backend
  count here IS the effective server-pool size; queueing surfaces as app-side
  DBConnection timeouts.
  """
  def snapshot(opts \\ []) do
    long_secs = Keyword.get(opts, :long_query_seconds, 300)
    max_conn = max_connections()

    by_db =
      query!(
        """
        SELECT datname, count(*)::int AS count
        FROM pg_stat_activity
        WHERE datname IS NOT NULL
        GROUP BY datname
        ORDER BY count DESC
        """,
        []
      )

    total = Enum.reduce(by_db, 0, fn %{count: c}, acc -> acc + c end)
    long = long_running_queries(long_secs)
    evaluate(total, max_conn, by_db, long, long_secs)
  end

  # Pure threshold logic — unit-testable without a DB.
  @doc false
  def evaluate(total, max_conn, by_db, long, long_secs) do
    usage_pct = if max_conn > 0, do: round(total * 100 / max_conn), else: 0

    {status, warnings} =
      {:ok, []}
      |> add_if(
        usage_pct > @crit_pct,
        :crit,
        "backends #{total}/#{max_conn} (#{usage_pct}%) over #{@crit_pct}% ceiling"
      )
      |> add_if(
        usage_pct > @warn_pct,
        :warn,
        "backends #{total}/#{max_conn} (#{usage_pct}%) over #{@warn_pct}%"
      )
      |> add_if(long != [], :warn, "#{length(long)} query(s) active > #{long_secs}s")

    %{
      total_backends: total,
      max_connections: max_conn,
      usage_pct: usage_pct,
      by_database: by_db,
      long_running: long,
      status: status,
      warnings: Enum.reverse(warnings)
    }
  end

  # Escalate status (ok < warn < crit) and collect a warning when `cond?` holds.
  defp add_if({status, warnings}, false, _level, _msg), do: {status, warnings}

  defp add_if({status, warnings}, true, level, msg),
    do: {escalate(status, level), [msg | warnings]}

  defp escalate(:crit, _), do: :crit
  defp escalate(_, :crit), do: :crit
  defp escalate(:warn, _), do: :warn
  defp escalate(_, :warn), do: :warn
  defp escalate(_, _), do: :ok

  defp query!(sql, params) do
    %{rows: rows, columns: cols} = Repo.query!(sql, params)
    # Atom keys to match the documented contract. Safe here: column names come
    # from our own fixed SELECT aliases, not from user input.
    keys = Enum.map(cols, &String.to_atom/1)
    Enum.map(rows, fn row -> keys |> Enum.zip(row) |> Map.new() end)
  end
end

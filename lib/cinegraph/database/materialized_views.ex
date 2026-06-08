defmodule Cinegraph.Database.MaterializedViews do
  @moduledoc """
  The single safe path for refreshing Postgres materialized views (GitHub #1019).

  Every refresh goes through `refresh!/2`, which:

    * uses `REFRESH MATERIALIZED VIEW CONCURRENTLY` when the view has a unique
      index (non-blocking for readers), and a plain locking `REFRESH` otherwise;
    * runs under a **server-side** `statement_timeout`, so a wedged refresh
      self-aborts and releases its locks instead of running for hours (the
      original incident: a 19.5 h `person_collaboration_trends` refresh that
      saturated the shared connection pool).

  The server-side timeout is set with `set_config('statement_timeout', _, true)`
  inside a transaction (`SET` cannot take a bind parameter; the `true` makes it
  transaction-local). The Ecto client timeout is `:infinity` on purpose — the
  database, not the client, owns the bound. `REFRESH ... CONCURRENTLY` is
  transaction-safe and the timeout is enforced (verified against Postgres 18).

  Callers: the `cinegraph.materialized_views.refresh` mix task,
  `Mix.Tasks.Db.PullProduction`, `Cinegraph.Collaborations.refresh_collaboration_trends/0`,
  and the scheduled `Cinegraph.Workers.MaterializedViewRefreshSweeper`.
  `Cinegraph.Movies.DiscoveryRankings` uses the lower-level `refresh_statement!/3`
  so it keeps its own unpopulated-view fallback while still getting the timeout.
  """

  alias Cinegraph.Database.Utils, as: DatabaseUtils
  alias Cinegraph.Repo

  require Logger

  @default_statement_timeout "60min"

  @doc "List all materialized views in the `public` schema (sorted)."
  def list_public do
    %{rows: rows} =
      Repo.query!(
        "SELECT matviewname FROM pg_matviews WHERE schemaname = 'public' ORDER BY matviewname",
        []
      )

    List.flatten(rows)
  end

  @doc """
  Refresh a single materialized view by (unqualified, public-schema) name.

  Options:

    * `:statement_timeout` — server-side timeout string (default `"#{@default_statement_timeout}"`).
    * `:concurrently_only` — when `true`, views lacking a unique index are skipped
      rather than blocking-refreshed; returns `{:skipped, :no_unique_index}`. Use
      this on cron so a scheduled job can never take an `ACCESS EXCLUSIVE` lock.

  Returns `:ok`, `{:skipped, reason}`, or raises on a DB error / timeout.
  """
  def refresh!(name, opts \\ []) when is_binary(name) do
    concurrently_only? = Keyword.get(opts, :concurrently_only, false)
    concurrent? = DatabaseUtils.has_unique_index?(name)

    cond do
      # A never-populated matview (created WITH NO DATA) cannot be refreshed
      # CONCURRENTLY — Postgres rejects it. The first populate must be a plain
      # REFRESH, which is safe here even from cron: an empty matview has no
      # readers to lock out (the #1019 concern was ACCESS EXCLUSIVE on a view
      # in active use). Without this branch the sweeper would crash and abort
      # the rest of its run whenever a new WITH-NO-DATA matview ships.
      not populated?(name) ->
        Logger.info("MaterializedViews: first populate of #{name} (plain REFRESH — unpopulated)")
        refresh_statement!(name, false, opts)
        :ok

      concurrent? ->
        refresh_statement!(name, true, opts)
        :ok

      concurrently_only? ->
        Logger.warning(
          "MaterializedViews: skipping #{name} — no unique index, concurrently_only requested"
        )

        {:skipped, :no_unique_index}

      true ->
        Logger.info(
          "MaterializedViews: refreshing #{name} with a locking REFRESH (no unique index)"
        )

        refresh_statement!(name, false, opts)
        :ok
    end
  end

  @doc """
  Refresh every materialized view in `public`. Returns `%{name => result}` where each
  result is `:ok | {:skipped, reason} | {:error, message}`.

  **Per-view isolation (#1088):** a `refresh!` that raises for ONE view must never abort
  the others. Each view is wrapped here so a single broken matview (e.g. a SQL underflow
  in its defining query) degrades to one `{:error, _}` entry instead of crashing the whole
  sweep and leaving every healthy view stale. `refresh!/2` itself still raises — isolation
  lives only in this aggregate.

  Accepts the same options as `refresh!/2`.
  """
  def refresh_all!(opts \\ []) do
    Map.new(list_public(), fn name ->
      result =
        try do
          refresh!(name, opts)
        rescue
          e ->
            Logger.error("MaterializedViews: refresh failed for #{name}: #{Exception.message(e)}")
            {:error, Exception.message(e)}
        end

      {name, result}
    end)
  end

  @doc """
  Execute a single `REFRESH` on `name` (concurrent or plain) under a **server-side**
  `statement_timeout`.

  Lower-level building block behind `refresh!/2`. Call it directly only when you
  need to control the concurrent flag yourself — e.g.
  `Cinegraph.Movies.DiscoveryRankings`, which orchestrates its own
  unpopulated-view fallback and metadata. Options: `:statement_timeout` (default
  `"#{@default_statement_timeout}"`). Raises on DB error / timeout.
  """
  def refresh_statement!(name, concurrently?, opts \\ [])
      when is_binary(name) and is_boolean(concurrently?) do
    timeout = Keyword.get(opts, :statement_timeout, @default_statement_timeout)
    qualified = quoted_public_name(name)
    concurrent_sql = if concurrently?, do: "CONCURRENTLY ", else: ""

    {:ok, _} =
      Repo.transaction(
        fn ->
          # Transaction-local server-side timeout: a stuck refresh aborts and the
          # transaction rolls back (old matview contents preserved).
          Repo.query!("SELECT set_config('statement_timeout', $1, true)", [timeout])

          Repo.query!("REFRESH MATERIALIZED VIEW #{concurrent_sql}#{qualified}", [],
            timeout: :infinity
          )
        end,
        timeout: :infinity
      )

    :ok
  end

  # WITH NO DATA matviews report ispopulated = false until their first REFRESH.
  defp populated?(name) do
    %{rows: rows} =
      Repo.query!(
        "SELECT ispopulated FROM pg_matviews WHERE schemaname = 'public' AND matviewname = $1",
        [name]
      )

    rows != [[false]]
  end

  defp quoted_public_name(name) do
    %{rows: [[qualified]]} =
      Repo.query!("SELECT quote_ident('public') || '.' || quote_ident($1)", [name])

    qualified
  end
end

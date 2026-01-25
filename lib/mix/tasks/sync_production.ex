defmodule Mix.Tasks.SyncProduction do
  @moduledoc """
  Sync production PlanetScale Postgres database to local development.

  This task automates the process of:
  1. Exporting the production database using pg_dump
  2. Dropping and recreating the local database
  3. Importing the dump using pg_restore
  4. Verifying the import was successful

  ## Usage

      # Full sync (drops local, imports fresh)
      mix sync_production

      # Export only (saves dump file)
      mix sync_production --export-only

      # Import from existing dump
      mix sync_production --import-only --dump-file priv/dumps/planetscale_20250125.dump

      # Parallel operations (faster for large DBs)
      mix sync_production --parallel 4

      # Verbose mode with progress
      mix sync_production --verbose

      # Skip verification step
      mix sync_production --skip-verify

      # Keep dump file after import (default: keeps it)
      mix sync_production --no-keep-dump

  ## Environment Variables Required

  The following environment variables must be set (typically in .env):

      DATABASE_HOST=eu-central-1.pg.psdb.cloud
      DATABASE_USERNAME=postgres.xxxxx
      DATABASE_PASSWORD=xxxxx
      DATABASE=postgres  # optional, defaults to "postgres"

  ## Notes

  - Both source (PlanetScale) and target (local) are PostgreSQL
  - Uses pg_dump custom format (-Fc) for compression
  - Requires pg_dump, pg_restore, dropdb, createdb in PATH
  - SSL is required for PlanetScale connections
  """

  use Mix.Task
  require Logger

  @shortdoc "Sync PlanetScale Postgres to local database"

  # Configuration
  @dump_dir "priv/dumps"
  @local_db "cinegraph_dev"
  @local_user "postgres"
  @local_password "postgres"
  @local_host "localhost"
  @local_port "5432"

  # Tables to verify after import
  @verify_tables ~w(movies people movie_credits collaborations festival_events genres)

  @impl Mix.Task
  def run(args) do
    # Load .env file for credentials
    load_env()

    # Parse options
    {opts, _, _} =
      OptionParser.parse(args,
        switches: [
          export_only: :boolean,
          import_only: :boolean,
          dump_file: :string,
          verbose: :boolean,
          skip_verify: :boolean,
          parallel: :integer,
          keep_dump: :boolean
        ],
        aliases: [
          e: :export_only,
          i: :import_only,
          f: :dump_file,
          v: :verbose,
          p: :parallel
        ]
      )

    # Default to keeping dump files
    opts = Keyword.put_new(opts, :keep_dump, true)

    # Execute based on options
    result =
      cond do
        opts[:export_only] ->
          export_database(opts)

        opts[:import_only] ->
          if opts[:dump_file] do
            import_only(opts)
          else
            error("--import-only requires --dump-file path")
            {:error, "Missing dump file"}
          end

        true ->
          full_sync(opts)
      end

    case result do
      {:ok, _} -> :ok
      {:error, reason} -> Mix.raise("Sync failed: #{reason}")
    end
  end

  defp full_sync(opts) do
    start_time = System.monotonic_time(:second)

    info("\n🔄 Starting full production sync...\n")

    with {:ok, dump_path} <- export_database(opts),
         :ok <- prepare_local_database(opts),
         :ok <- import_database(dump_path, opts),
         :ok <- post_import_cleanup(opts),
         :ok <- maybe_verify(opts) do
      elapsed = System.monotonic_time(:second) - start_time
      info("\n✅ Sync completed successfully in #{elapsed}s")
      {:ok, dump_path}
    else
      {:error, reason} ->
        error("\n❌ Sync failed: #{reason}")
        {:error, reason}
    end
  end

  defp import_only(opts) do
    start_time = System.monotonic_time(:second)
    dump_path = opts[:dump_file]

    info("\n🔄 Starting import from #{dump_path}...\n")

    unless File.exists?(dump_path) do
      error("Dump file not found: #{dump_path}")
      {:error, "Dump file not found"}
    end

    with :ok <- prepare_local_database(opts),
         :ok <- import_database(dump_path, opts),
         :ok <- post_import_cleanup(opts),
         :ok <- maybe_verify(opts) do
      elapsed = System.monotonic_time(:second) - start_time
      info("\n✅ Import completed successfully in #{elapsed}s")
      {:ok, dump_path}
    else
      {:error, reason} ->
        error("\n❌ Import failed: #{reason}")
        {:error, reason}
    end
  end

  # ============================================================================
  # Export Phase
  # ============================================================================

  defp export_database(opts) do
    info("📤 Exporting from PlanetScale...")

    with {:ok, creds} <- get_production_credentials(),
         :ok <- ensure_dump_dir(),
         {:ok, dump_path} <- run_pg_dump(creds, opts) do
      {:ok, dump_path}
    end
  end

  defp get_production_credentials do
    host = System.get_env("DATABASE_HOST")
    username = System.get_env("DATABASE_USERNAME")
    password = System.get_env("DATABASE_PASSWORD")
    database = System.get_env("DATABASE") || "postgres"
    port = System.get_env("DATABASE_PORT") || "5432"

    cond do
      is_nil(host) ->
        error("  ✗ DATABASE_HOST environment variable not set")
        {:error, "Missing DATABASE_HOST"}

      is_nil(username) ->
        error("  ✗ DATABASE_USERNAME environment variable not set")
        {:error, "Missing DATABASE_USERNAME"}

      is_nil(password) ->
        error("  ✗ DATABASE_PASSWORD environment variable not set")
        {:error, "Missing DATABASE_PASSWORD"}

      true ->
        verbose_info("  → Connecting to #{host}:#{port}/#{database}")

        {:ok,
         %{
           host: host,
           username: username,
           password: password,
           database: database,
           port: port
         }}
    end
  end

  defp ensure_dump_dir do
    File.mkdir_p!(@dump_dir)
    :ok
  end

  defp run_pg_dump(creds, opts) do
    timestamp =
      DateTime.utc_now()
      |> DateTime.to_iso8601(:basic)
      |> String.slice(0, 15)
      |> String.replace("T", "_")

    dump_path = Path.join(@dump_dir, "planetscale_#{timestamp}.dump")
    parallel_arg = if opts[:parallel], do: "-j #{opts[:parallel]}", else: ""

    # Build connection string with SSL
    # PlanetScale requires SSL with verify-full
    conn_string =
      "postgresql://#{creds.username}:#{URI.encode_www_form(creds.password)}@#{creds.host}:#{creds.port}/#{creds.database}?sslmode=require"

    cmd = """
    pg_dump '#{conn_string}' \
      -Fc \
      --no-owner \
      --no-acl \
      #{parallel_arg} \
      -f '#{dump_path}' \
      2>&1
    """

    verbose_info("  → Running pg_dump...")

    case System.cmd("sh", ["-c", cmd], stderr_to_stdout: true) do
      {_output, 0} ->
        size = File.stat!(dump_path).size |> format_size()
        info("  ✓ Exported to #{dump_path} (#{size})")
        {:ok, dump_path}

      {output, code} ->
        # Sanitize output to remove password
        sanitized = String.replace(output, creds.password, "***")
        error("  ✗ pg_dump failed (exit code #{code})")
        verbose_info("  Output: #{sanitized}")
        {:error, "pg_dump failed: #{sanitized}"}
    end
  end

  # ============================================================================
  # Preparation Phase
  # ============================================================================

  defp prepare_local_database(_opts) do
    info("🗄️  Preparing local database...")

    with :ok <- drop_local_database(),
         :ok <- create_local_database() do
      :ok
    end
  end

  defp drop_local_database do
    cmd =
      "PGPASSWORD='#{@local_password}' dropdb --if-exists -h #{@local_host} -p #{@local_port} -U #{@local_user} #{@local_db} 2>&1"

    case System.cmd("sh", ["-c", cmd], stderr_to_stdout: true) do
      {_output, 0} ->
        info("  ✓ Dropped existing database")
        :ok

      {output, _code} ->
        if String.contains?(output, "does not exist") do
          info("  ✓ No existing database to drop")
          :ok
        else
          error("  ✗ Failed to drop database: #{output}")
          {:error, "Failed to drop database"}
        end
    end
  end

  defp create_local_database do
    cmd =
      "PGPASSWORD='#{@local_password}' createdb -h #{@local_host} -p #{@local_port} -U #{@local_user} #{@local_db} 2>&1"

    case System.cmd("sh", ["-c", cmd], stderr_to_stdout: true) do
      {_output, 0} ->
        info("  ✓ Created fresh database")
        :ok

      {output, _code} ->
        error("  ✗ Failed to create database: #{output}")
        {:error, "Failed to create database"}
    end
  end

  # ============================================================================
  # Import Phase
  # ============================================================================

  defp import_database(dump_path, opts) do
    info("📥 Importing to local database...")

    unless File.exists?(dump_path) do
      error("  ✗ Dump file not found: #{dump_path}")
      {:error, "Dump file not found"}
    end

    parallel_arg = if opts[:parallel], do: "-j #{opts[:parallel]}", else: ""

    cmd = """
    PGPASSWORD='#{@local_password}' pg_restore \
      -h #{@local_host} \
      -p #{@local_port} \
      -U #{@local_user} \
      -d #{@local_db} \
      --no-owner \
      --no-acl \
      #{parallel_arg} \
      '#{dump_path}' \
      2>&1
    """

    verbose_info("  → Running pg_restore...")

    case System.cmd("sh", ["-c", cmd], stderr_to_stdout: true) do
      {_output, 0} ->
        info("  ✓ Import completed")
        :ok

      {output, _code} ->
        # pg_restore often returns non-zero for warnings, check for actual errors
        if has_critical_errors?(output) do
          error("  ✗ pg_restore failed")
          verbose_info("  Output: #{String.slice(output, 0, 500)}")
          {:error, "pg_restore failed"}
        else
          info("  ✓ Import completed (with warnings)")
          verbose_info("  Warnings: #{String.slice(output, 0, 200)}")
          :ok
        end
    end
  end

  defp has_critical_errors?(output) do
    critical_patterns = [
      "FATAL:",
      "could not connect",
      "connection refused",
      "authentication failed",
      "invalid input syntax",
      "violates foreign key constraint"
    ]

    Enum.any?(critical_patterns, &String.contains?(output, &1))
  end

  # ============================================================================
  # Post-Import Cleanup
  # ============================================================================

  defp post_import_cleanup(_opts) do
    info("🧹 Running post-import cleanup...")

    # Start the application to use Ecto
    {:ok, _} = Application.ensure_all_started(:postgrex)
    {:ok, _} = Application.ensure_all_started(:ecto_sql)

    # Start repo manually for this task
    case start_repo() do
      {:ok, _pid} ->
        with :ok <- clean_oban_jobs(),
             :ok <- reset_sequences(),
             :ok <- refresh_materialized_views() do
          :ok
        end

      {:error, {:already_started, _}} ->
        with :ok <- clean_oban_jobs(),
             :ok <- reset_sequences(),
             :ok <- refresh_materialized_views() do
          :ok
        end

      {:error, reason} ->
        error("  ✗ Failed to start repo: #{inspect(reason)}")
        # Continue anyway - cleanup is optional
        info("  ⚠ Skipping cleanup steps")
        :ok
    end
  end

  defp start_repo do
    # Get repo config from dev environment
    # Use longer timeout for post-import operations like materialized view refresh
    repo_config = [
      username: @local_user,
      password: @local_password,
      hostname: @local_host,
      port: String.to_integer(@local_port),
      database: @local_db,
      pool_size: 2,
      timeout: 120_000
    ]

    Cinegraph.Repo.start_link(repo_config)
  end

  defp clean_oban_jobs do
    verbose_info("  → Cleaning Oban jobs...")

    queries = [
      "DELETE FROM oban_jobs WHERE state IN ('scheduled', 'available', 'executing')",
      "DELETE FROM oban_peers"
    ]

    Enum.each(queries, fn query ->
      case Cinegraph.Repo.query(query) do
        {:ok, result} ->
          verbose_info("    Cleaned #{result.num_rows} rows")

        {:error, %{postgres: %{code: :undefined_table}}} ->
          verbose_info("    Table doesn't exist, skipping")

        {:error, reason} ->
          verbose_info("    Warning: #{inspect(reason)}")
      end
    end)

    info("  ✓ Cleaned Oban jobs")
    :ok
  end

  defp reset_sequences do
    verbose_info("  → Resetting sequences...")

    # Query to generate reset commands for all sequences
    query = """
    SELECT 'SELECT setval(' ||
           quote_literal(quote_ident(schemaname) || '.' || quote_ident(sequencename)) ||
           ', COALESCE((SELECT MAX(id) FROM ' ||
           quote_ident(schemaname) || '.' || quote_ident(replace(sequencename, '_id_seq', '')) ||
           '), 1))' AS reset_cmd
    FROM pg_sequences
    WHERE schemaname = 'public'
    AND sequencename LIKE '%_id_seq'
    """

    case Cinegraph.Repo.query(query) do
      {:ok, %{rows: rows}} ->
        reset_count =
          Enum.reduce(rows, 0, fn [cmd], acc ->
            case Cinegraph.Repo.query(cmd) do
              {:ok, _} -> acc + 1
              {:error, _} -> acc
            end
          end)

        info("  ✓ Reset #{reset_count} sequences")

      {:error, reason} ->
        verbose_info("  ⚠ Could not reset sequences: #{inspect(reason)}")
    end

    :ok
  end

  defp refresh_materialized_views do
    verbose_info("  → Refreshing materialized views...")

    # Find all materialized views
    query = """
    SELECT schemaname || '.' || matviewname
    FROM pg_matviews
    WHERE schemaname = 'public'
    """

    case Cinegraph.Repo.query(query) do
      {:ok, %{rows: rows}} ->
        Enum.each(rows, fn [view_name] ->
          verbose_info("    Refreshing #{view_name}...")

          case Cinegraph.Repo.query("REFRESH MATERIALIZED VIEW #{view_name}") do
            {:ok, _} -> :ok
            {:error, reason} -> verbose_info("    Warning: #{inspect(reason)}")
          end
        end)

        if length(rows) > 0 do
          info("  ✓ Refreshed #{length(rows)} materialized views")
        else
          verbose_info("  → No materialized views to refresh")
        end

      {:error, reason} ->
        verbose_info("  ⚠ Could not refresh views: #{inspect(reason)}")
    end

    :ok
  end

  # ============================================================================
  # Verification Phase
  # ============================================================================

  defp maybe_verify(opts) do
    if opts[:skip_verify] do
      info("⏭️  Skipping verification")
      :ok
    else
      verify_import()
    end
  end

  defp verify_import do
    info("🔍 Verifying import...")

    results =
      Enum.map(@verify_tables, fn table ->
        count = get_table_count(table)
        info("  #{String.pad_trailing(table <> ":", 20)} #{format_number(count)} records")
        {table, count}
      end)

    # Check for empty critical tables
    critical_tables = ~w(movies people)

    empty_critical =
      Enum.filter(results, fn {table, count} ->
        count == 0 && table in critical_tables
      end)

    if Enum.empty?(empty_critical) do
      info("  ✓ All critical tables have data")
      :ok
    else
      tables = Enum.map(empty_critical, &elem(&1, 0)) |> Enum.join(", ")
      error("  ✗ Critical tables are empty: #{tables}")
      {:error, "Critical tables empty"}
    end
  end

  defp get_table_count(table) do
    case Cinegraph.Repo.query("SELECT COUNT(*) FROM #{table}") do
      {:ok, %{rows: [[count]]}} -> count
      _ -> 0
    end
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp load_env do
    # Load .env file if it exists
    env_file = Path.join(File.cwd!(), ".env")

    if File.exists?(env_file) do
      env_file
      |> File.read!()
      |> String.split("\n")
      |> Enum.each(fn line ->
        case String.split(line, "=", parts: 2) do
          [key, value] ->
            key = String.trim(key)
            value = String.trim(value) |> String.trim("\"") |> String.trim("'")

            unless String.starts_with?(key, "#") || key == "" do
              System.put_env(key, value)
            end

          _ ->
            :ok
        end
      end)

      verbose_info("Loaded environment from .env")
    end
  end

  defp format_size(bytes) when bytes < 1024, do: "#{bytes} B"
  defp format_size(bytes) when bytes < 1_048_576, do: "#{Float.round(bytes / 1024, 1)} KB"
  defp format_size(bytes) when bytes < 1_073_741_824, do: "#{Float.round(bytes / 1_048_576, 1)} MB"
  defp format_size(bytes), do: "#{Float.round(bytes / 1_073_741_824, 2)} GB"

  defp format_number(num) when num < 1000, do: "#{num}"

  defp format_number(num) do
    num
    |> Integer.to_string()
    |> String.graphemes()
    |> Enum.reverse()
    |> Enum.chunk_every(3)
    |> Enum.join(",")
    |> String.reverse()
  end

  defp info(message), do: Mix.shell().info(message)
  defp error(message), do: Mix.shell().error(message)

  defp verbose_info(message) do
    # Always show in verbose mode, but for now show important messages
    if Application.get_env(:cinegraph, :verbose_sync, false) do
      Mix.shell().info(message)
    end
  end
end

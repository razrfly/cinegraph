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

    # Wire verbose flag to application env so verbose_info/1 works
    if opts[:verbose] do
      Application.put_env(:cinegraph, :verbose_sync, true)
    end

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
         :ok <- maybe_verify(opts),
         :ok <- maybe_cleanup_dump(dump_path, opts) do
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

    with :ok <- ensure_dump_file(dump_path, "import_only"),
         :ok <- prepare_local_database(opts),
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

    # pg_dump's -j/--jobs only works with directory format (-Fd), not custom format (-Fc)
    # Since we use custom format for compression, warn and ignore the parallel option
    parallel_arg =
      if opts[:parallel] do
        info("  ⚠ --parallel ignored for pg_dump: -j/--jobs requires directory format (-Fd)")

        info(
          "    Using custom format (-Fc) for compression. Parallel is supported during restore."
        )

        ""
      else
        ""
      end

    # Build connection string with SSL and connection timeout
    # PlanetScale requires SSL
    conn_string =
      "postgresql://#{creds.username}:#{URI.encode_www_form(creds.password)}@#{creds.host}:#{creds.port}/#{creds.database}?sslmode=require&connect_timeout=30"

    # Use --verbose to get table-by-table progress
    cmd = """
    pg_dump '#{conn_string}' \
      -Fc \
      --no-owner \
      --no-acl \
      --verbose \
      #{parallel_arg} \
      -f '#{dump_path}' \
      2>&1
    """

    info("  → Connecting to #{creds.host}...")

    # Start progress monitor that also tracks activity
    parent = self()
    monitor_pid = spawn_link(fn -> monitor_dump_progress(dump_path, parent) end)
    start_time = System.monotonic_time(:second)

    # Run pg_dump and capture output for verbose table progress
    port = Port.open({:spawn, "sh -c \"#{cmd}\""}, [:binary, :exit_status, :stderr_to_stdout])

    result = collect_dump_output(port, creds.password, [], monitor_pid)

    # Stop the monitor
    send(monitor_pid, :stop)

    elapsed = System.monotonic_time(:second) - start_time

    case result do
      {:ok, _output} ->
        # Clear the progress line and show final result
        IO.write("\r\e[K")
        size = File.stat!(dump_path).size |> format_size()
        info("  ✓ Exported to #{dump_path} (#{size}) in #{elapsed}s")
        {:ok, dump_path}

      {:error, output, code} ->
        IO.write("\r\e[K")
        # Sanitize output to remove password
        sanitized = String.replace(output, creds.password, "***")
        error("  ✗ pg_dump failed (exit code #{code})")
        verbose_info("  Output: #{sanitized}")
        {:error, "pg_dump failed: #{sanitized}"}
    end
  end

  defp collect_dump_output(port, password, acc, monitor_pid) do
    receive do
      {^port, {:data, data}} ->
        # Notify monitor of activity
        send(monitor_pid, :activity)

        # Sanitize password from output
        sanitized = String.replace(data, password, "***")

        # Show table progress from verbose output
        sanitized
        |> String.split("\n")
        |> Enum.each(fn line ->
          line = String.trim(line)

          cond do
            line == "" ->
              :ok

            String.contains?(line, "dumping contents of table") ->
              table = extract_table_name(line)
              IO.write("\r\e[K  → Dumping: #{table}...")

            String.contains?(line, "saving") && String.contains?(line, "statistics") ->
              IO.write("\r\e[K  → Saving statistics...")

            # Show errors and important messages
            String.contains?(String.downcase(line), "error") ||
              String.contains?(String.downcase(line), "fatal") ||
              String.contains?(String.downcase(line), "failed") ||
              String.contains?(String.downcase(line), "denied") ||
                String.contains?(String.downcase(line), "refused") ->
              IO.write("\r\e[K")
              IO.puts("  ⚠ #{line}")

            # Show connection progress
            String.contains?(line, "reading") ||
              String.contains?(line, "identifying") ||
                String.contains?(line, "started") ->
              IO.write("\r\e[K  → #{line}")

            true ->
              :ok
          end
        end)

        collect_dump_output(port, password, [sanitized | acc], monitor_pid)

      {^port, {:exit_status, 0}} ->
        {:ok, acc |> Enum.reverse() |> Enum.join()}

      {^port, {:exit_status, code}} ->
        output = acc |> Enum.reverse() |> Enum.join()
        # Show the last part of output for debugging
        if String.length(output) > 0 do
          IO.write("\r\e[K")
          IO.puts("  Debug output:")

          output
          |> String.split("\n")
          |> Enum.take(-10)
          |> Enum.each(&IO.puts("    #{&1}"))
        end

        {:error, output, code}

      {:timeout_stalled} ->
        Port.close(port)
        output = acc |> Enum.reverse() |> Enum.join()
        IO.puts("\n  Last output before stall timeout:")

        output
        |> String.split("\n")
        |> Enum.take(-5)
        |> Enum.each(&IO.puts("    #{&1}"))

        {:error, "No progress for 15 minutes - connection may have stalled", 1}
    end
  end

  defp extract_table_name(line) do
    case Regex.run(~r/table "?([^"]+)"?\.?"?([^"]+)"?/, line) do
      [_, schema, table] ->
        "#{schema}.#{table}"

      _ ->
        case Regex.run(~r/table (\S+)/, line) do
          [_, table] -> table
          _ -> "..."
        end
    end
  end

  defp monitor_dump_progress(dump_path, parent) do
    monitor_dump_progress(
      dump_path,
      parent,
      System.monotonic_time(:second),
      0,
      System.monotonic_time(:second)
    )
  end

  # Monitor file size growth and detect stalls
  # Only timeout if NO file growth AND NO output for 15 minutes
  defp monitor_dump_progress(dump_path, parent, start_time, last_size, last_activity_time) do
    receive do
      :stop ->
        :ok

      :activity ->
        # Reset activity timer when we get output
        monitor_dump_progress(
          dump_path,
          parent,
          start_time,
          last_size,
          System.monotonic_time(:second)
        )
    after
      2000 ->
        now = System.monotonic_time(:second)

        case File.stat(dump_path) do
          {:ok, %{size: size}} when size > 0 ->
            elapsed = now - start_time
            rate = if elapsed > 0, do: size / elapsed, else: 0

            # Check if file is growing
            file_growing = size > last_size
            new_activity_time = if file_growing, do: now, else: last_activity_time

            # Only update display if size changed
            if size != last_size do
              size_str = format_size(size)
              rate_str = format_size(round(rate)) <> "/s"
              elapsed_str = format_duration(elapsed)
              IO.write("\r\e[K  → Exporting... #{size_str} (#{rate_str}) [#{elapsed_str}]")
            end

            # Check for stall - no activity for 15 minutes
            stall_duration = now - new_activity_time

            if stall_duration > 900 do
              IO.puts("\n  ⚠ No progress for #{div(stall_duration, 60)} minutes")
              send(parent, {:timeout_stalled})
            else
              monitor_dump_progress(dump_path, parent, start_time, size, new_activity_time)
            end

          _ ->
            # File doesn't exist yet, check for initial connection stall
            stall_duration = now - last_activity_time

            if stall_duration > 300 do
              IO.puts("\n  ⚠ No response for #{div(stall_duration, 60)} minutes")
              send(parent, {:timeout_stalled})
            else
              monitor_dump_progress(dump_path, parent, start_time, last_size, last_activity_time)
            end
        end
    end
  end

  defp format_duration(seconds) when seconds < 60, do: "#{seconds}s"

  defp format_duration(seconds) when seconds < 3600 do
    mins = div(seconds, 60)
    secs = rem(seconds, 60)
    "#{mins}m #{secs}s"
  end

  defp format_duration(seconds) do
    hours = div(seconds, 3600)
    mins = div(rem(seconds, 3600), 60)
    "#{hours}h #{mins}m"
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

    with :ok <- ensure_dump_file(dump_path, "import_database") do
      do_import_database(dump_path, opts)
    end
  end

  defp do_import_database(dump_path, opts) do
    dump_size = File.stat!(dump_path).size
    info("  → Restoring #{format_size(dump_size)} dump...")

    parallel_arg = if opts[:parallel], do: "-j #{opts[:parallel]}", else: ""

    # Use --verbose to get table-by-table progress
    cmd = """
    PGPASSWORD='#{@local_password}' pg_restore \
      -h #{@local_host} \
      -p #{@local_port} \
      -U #{@local_user} \
      -d #{@local_db} \
      --no-owner \
      --no-acl \
      --verbose \
      #{parallel_arg} \
      '#{dump_path}' \
      2>&1
    """

    start_time = System.monotonic_time(:second)

    # Run pg_restore and capture output for progress
    port = Port.open({:spawn, "sh -c \"#{cmd}\""}, [:binary, :exit_status, :stderr_to_stdout])

    result = collect_restore_output(port, [])

    elapsed = System.monotonic_time(:second) - start_time

    case result do
      {:ok, _output} ->
        IO.write("\r\e[K")
        info("  ✓ Import completed in #{elapsed}s")
        :ok

      {:error, output, _code} ->
        IO.write("\r\e[K")
        # pg_restore often returns non-zero for warnings, check for actual errors
        if has_critical_errors?(output) do
          error("  ✗ pg_restore failed")
          verbose_info("  Output: #{String.slice(output, 0, 500)}")
          {:error, "pg_restore failed"}
        else
          info("  ✓ Import completed in #{elapsed}s (with warnings)")
          :ok
        end
    end
  end

  defp collect_restore_output(port, acc) do
    receive do
      {^port, {:data, data}} ->
        # Show table progress from verbose output
        data
        |> String.split("\n")
        |> Enum.each(fn line ->
          cond do
            String.contains?(line, "processing data for table") ->
              table = extract_restore_table_name(line)
              IO.write("\r\e[K  → Restoring: #{table}...")

            String.contains?(line, "creating INDEX") ->
              IO.write("\r\e[K  → Creating indexes...")

            String.contains?(line, "creating CONSTRAINT") ->
              IO.write("\r\e[K  → Creating constraints...")

            String.contains?(line, "creating TRIGGER") ->
              IO.write("\r\e[K  → Creating triggers...")

            String.contains?(line, "creating FK CONSTRAINT") ->
              IO.write("\r\e[K  → Creating foreign keys...")

            true ->
              :ok
          end
        end)

        collect_restore_output(port, [data | acc])

      {^port, {:exit_status, 0}} ->
        {:ok, acc |> Enum.reverse() |> Enum.join()}

      {^port, {:exit_status, code}} ->
        {:error, acc |> Enum.reverse() |> Enum.join(), code}
    after
      1_800_000 ->
        Port.close(port)
        {:error, "Timeout after 30 minutes", 1}
    end
  end

  defp extract_restore_table_name(line) do
    case Regex.run(~r/table "?public"?\."?([^"]+)"?/, line) do
      [_, table] ->
        table

      _ ->
        case Regex.run(~r/table (\S+)/, line) do
          [_, table] -> table
          _ -> "..."
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

  defp ensure_dump_file(path, prefix) do
    if File.exists?(path) do
      :ok
    else
      error("  ✗ [#{prefix}] Dump file not found: #{path}")
      {:error, "Dump file not found: #{path}"}
    end
  end

  defp maybe_cleanup_dump(dump_path, opts) do
    if opts[:keep_dump] do
      verbose_info("  → Keeping dump file: #{dump_path}")
      :ok
    else
      case File.rm(dump_path) do
        :ok ->
          info("  🗑️  Removed dump file: #{dump_path}")
          :ok

        {:error, reason} ->
          error("  ⚠ Failed to remove dump file: #{inspect(reason)}")
          # Don't fail the whole sync just because cleanup failed
          :ok
      end
    end
  end

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

  defp format_size(bytes) when bytes < 1_073_741_824,
    do: "#{Float.round(bytes / 1_048_576, 1)} MB"

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

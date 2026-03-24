defmodule Mix.Tasks.Db.PullProduction do
  @moduledoc """
  Pull the production database (cinegraph_prod) to local development (cinegraph_dev) via SSH.

  This task automates the process of:
  1. Exporting the production database using pg_dump over SSH
  2. Dropping and recreating the local database
  3. Importing the dump using pg_restore
  4. Verifying the import was successful

  ## Usage

      # Full sync (drops local, imports fresh)
      mix db.pull_production

      # Export only (saves dump file)
      mix db.pull_production --export-only

      # Import from existing dump
      mix db.pull_production --import-only --dump-file priv/dumps/cinegraph_prod_20260324_120000.dump

      # Parallel operations (faster for large DBs)
      mix db.pull_production --parallel 4

      # Verbose mode with progress
      mix db.pull_production --verbose

      # Skip verification step
      mix db.pull_production --skip-verify

      # Keep dump file after import (default: keeps it)
      mix db.pull_production --no-keep-dump

  ## Prerequisites

  - SSH access to 192.168.1.205 (key-based auth, no password prompt)
  - pg_dump and pg_restore in PATH (`brew install libpq` if missing)
  - Local PostgreSQL running

  ## Notes

  - Uses SSH to stream pg_dump output directly to a local file
  - Uses pg_dump custom format (-Fc) for compression
  - Dumps are saved to priv/dumps/ (gitignored)
  - Oban jobs are deleted after restore to prevent production jobs running locally
  """

  use Mix.Task
  require Logger

  @shortdoc "Pull production DB locally via SSH (cinegraph_prod → cinegraph_dev)"

  # Static configuration (compile-time)
  @dump_dir "priv/dumps"

  # Runtime configuration — override via environment variables
  defp local_db, do: System.get_env("LOCAL_DB", "cinegraph_dev")
  defp local_user, do: System.get_env("LOCAL_DB_USER", "postgres")
  defp local_password, do: System.get_env("LOCAL_DB_PASSWORD", "postgres")
  defp local_host, do: System.get_env("LOCAL_DB_HOST", "localhost")
  defp local_port, do: System.get_env("LOCAL_DB_PORT", "5432")

  # SSH / remote config — override via environment variables
  defp ssh_host, do: System.get_env("REMOTE_SSH_HOST", "192.168.1.205")
  defp remote_db_user, do: System.get_env("REMOTE_DB_USER", "holden")
  defp remote_db_name, do: System.get_env("REMOTE_DB_NAME", "cinegraph_prod")

  # Tables to verify after import
  @verify_tables ~w(movies people movie_credits collaborations festival_events genres)

  @impl Mix.Task
  def run(args) do
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

    case run_preflight_checks(opts) do
      :ok ->
        info("\n✅ Pre-flight checks passed\n")
        execute_sync(opts)

      {:error, reason} ->
        error("\n❌ Pre-flight failed: #{reason}")
        Mix.raise("Pre-flight checks failed")
    end
  end

  defp execute_sync(opts) do
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
  # Pre-flight Checks
  # ============================================================================

  defp run_preflight_checks(opts) do
    info("\n🔍 Running pre-flight checks...\n")

    checks =
      if opts[:import_only] do
        [
          {"Checking pg_restore in PATH", &check_pg_restore/0},
          {"Checking local PostgreSQL", &check_local_postgres/0}
        ]
      else
        [
          {"Checking SSH to #{ssh_host()}", &check_ssh_connectivity/0},
          {"Checking pg_dump on remote", &check_remote_pg_dump/0},
          {"Checking pg_restore in PATH", &check_pg_restore/0},
          {"Checking local PostgreSQL", &check_local_postgres/0}
        ]
      end

    run_checks(checks)
  end

  defp check_ssh_connectivity do
    case System.cmd(
           "ssh",
           ["-o", "ConnectTimeout=5", "-o", "BatchMode=yes", ssh_host(), "echo ok"],
           stderr_to_stdout: true
         ) do
      {"ok\n", 0} -> :ok
      {output, _} -> {:error, "Cannot SSH to #{ssh_host()}: #{String.trim(output)}"}
    end
  end

  defp check_remote_pg_dump do
    case System.cmd(
           "ssh",
           ["-o", "ConnectTimeout=5", "-o", "BatchMode=yes", ssh_host(), "which pg_dump"],
           stderr_to_stdout: true
         ) do
      {_, 0} -> :ok
      {output, _} -> {:error, "pg_dump not found on #{ssh_host()}: #{String.trim(output)}"}
    end
  end

  defp check_pg_restore do
    case System.cmd("which", ["pg_restore"], stderr_to_stdout: true) do
      {_, 0} -> :ok
      _ -> {:error, "pg_restore not found in PATH. Install via: brew install libpq"}
    end
  end

  defp check_local_postgres do
    args = [
      "-h",
      local_host(),
      "-p",
      local_port(),
      "-U",
      local_user(),
      "-c",
      "SELECT 1",
      "postgres"
    ]

    case System.cmd("psql", args, env: [{"PGPASSWORD", local_password()}], stderr_to_stdout: true) do
      {_, 0} ->
        :ok

      {output, _} ->
        if String.contains?(output, "connection refused") do
          {:error, "PostgreSQL not running. Start with: brew services start postgresql@16"}
        else
          {:error, "Cannot connect to local PostgreSQL: #{String.trim(output)}"}
        end
    end
  end

  defp run_checks([]), do: :ok

  defp run_checks([{label, check_fn} | rest]) do
    IO.write("  #{label}... ")

    case check_fn.() do
      :ok ->
        IO.puts("✓")
        run_checks(rest)

      {:error, reason} ->
        IO.puts("✗")
        {:error, reason}
    end
  end

  # ============================================================================
  # Export Phase
  # ============================================================================

  defp export_database(_opts) do
    info("📤 Exporting #{remote_db_name()} from #{ssh_host()} via SSH...")

    with :ok <- ensure_dump_dir(),
         {:ok, dump_path} <- run_pg_dump_via_ssh() do
      {:ok, dump_path}
    end
  end

  defp run_pg_dump_via_ssh do
    timestamp =
      DateTime.utc_now()
      |> DateTime.to_iso8601(:basic)
      |> String.slice(0, 15)
      |> String.replace("T", "_")

    dump_path = Path.join(@dump_dir, "cinegraph_prod_#{timestamp}.dump")

    # Stream pg_dump stdout over SSH into local file; stderr goes to our process
    # Use single quotes around the remote command to avoid double-quote nesting inside sh -c "..."
    cmd =
      ~s(ssh #{ssh_host()} 'pg_dump -U #{remote_db_user()} -Fc #{remote_db_name()}' > '#{dump_path}')

    info("  → Streaming dump from #{ssh_host()}...")

    parent = self()
    monitor_pid = spawn_link(fn -> monitor_dump_progress(dump_path, parent) end)
    start_time = System.monotonic_time(:second)

    port = Port.open({:spawn, "sh -c \"#{cmd}\""}, [:binary, :exit_status, :stderr_to_stdout])
    result = collect_ssh_output(port)

    send(monitor_pid, :stop)
    elapsed = System.monotonic_time(:second) - start_time

    case result do
      :ok ->
        IO.write("\r\e[K")
        size = File.stat!(dump_path).size |> format_size()
        info("  ✓ Exported to #{dump_path} (#{size}) in #{elapsed}s")
        {:ok, dump_path}

      {:error, _output, code} ->
        IO.write("\r\e[K")
        File.rm(dump_path)
        error("  ✗ pg_dump via SSH failed (exit #{code})")
        {:error, "pg_dump via SSH failed"}
    end
  end

  # SSH pipes pg_dump stdout directly to file; stderr/errors come through as port data
  defp collect_ssh_output(port) do
    receive do
      {^port, {:data, _data}} ->
        collect_ssh_output(port)

      {^port, {:exit_status, 0}} ->
        :ok

      {^port, {:exit_status, code}} ->
        {:error, "", code}

      {:timeout_stalled} ->
        Port.close(port)
        {:error, "No progress for 15 minutes", 1}
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
    # Use DROP DATABASE WITH (FORCE) to atomically terminate all connections and drop
    # This avoids race conditions with apps that reconnect between terminate and drop
    args = [
      "-h",
      local_host(),
      "-p",
      local_port(),
      "-U",
      local_user(),
      "-d",
      "postgres",
      "-c",
      "DROP DATABASE IF EXISTS #{local_db()} WITH (FORCE)"
    ]

    case System.cmd("psql", args, env: [{"PGPASSWORD", local_password()}], stderr_to_stdout: true) do
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
    args = ["-h", local_host(), "-p", local_port(), "-U", local_user(), local_db()]

    case System.cmd("createdb", args,
           env: [{"PGPASSWORD", local_password()}],
           stderr_to_stdout: true
         ) do
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
    PGPASSWORD='#{local_password()}' pg_restore \
      -h #{local_host()} \
      -p #{local_port()} \
      -U #{local_user()} \
      -d #{local_db()} \
      --no-owner \
      --no-acl \
      --verbose \
      #{parallel_arg} \
      '#{dump_path}' \
      2>&1
    """

    start_time = System.monotonic_time(:second)

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
    # Use longer timeout for post-import operations like materialized view refresh
    repo_config = [
      username: local_user(),
      password: local_password(),
      hostname: local_host(),
      port: String.to_integer(local_port()),
      database: local_db(),
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

    # Find all materialized views; quote_ident ensures the returned names are safe to
    # interpolate directly into the subsequent REFRESH MATERIALIZED VIEW statement.
    query = """
    SELECT quote_ident(schemaname) || '.' || quote_ident(matviewname)
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

  defp ensure_dump_dir do
    File.mkdir_p!(@dump_dir)
    :ok
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
    if Application.get_env(:cinegraph, :verbose_sync, false) do
      Mix.shell().info(message)
    end
  end
end

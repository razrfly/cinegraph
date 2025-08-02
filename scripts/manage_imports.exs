#!/usr/bin/env elixir
# Script to manage TMDb imports - pause, resume, status
# Run with: mix run scripts/manage_imports.exs

require Logger

# Parse command line arguments
{opts, args, _} = OptionParser.parse(System.argv(),
  switches: [
    help: :boolean
  ],
  aliases: [h: :help]
)

command = List.first(args)

if opts[:help] || is_nil(command) do
  IO.puts("""
  TMDb Import Manager - Monitor and control imports

  Usage: mix run scripts/manage_imports.exs <command> [args]

  Commands:
    status              Show status of all imports
    pause <id>          Pause a running import
    resume <id>         Resume a paused import
    help                Show this help message

  Examples:
    # Check status of all imports
    mix run scripts/manage_imports.exs status

    # Pause import with ID 5
    mix run scripts/manage_imports.exs pause 5

    # Resume import with ID 5
    mix run scripts/manage_imports.exs resume 5
  """)
  System.halt(0)
end

case command do
  "status" ->
    statuses = Cinegraph.Imports.TMDbImporter.get_import_status()
    
    if length(statuses) == 0 do
      Logger.info("No active imports found.")
    else
      Logger.info("Active imports:\n")
      
      Enum.each(statuses, fn status ->
        duration_str = if status.duration do
          minutes = div(status.duration, 60)
          seconds = rem(status.duration, 60)
          "#{minutes}m #{seconds}s"
        else
          "N/A"
        end
        
        Logger.info("""
        Import ID: #{status.id}
        Type: #{status.type}
        Status: #{status.status}
        Progress: Page #{status.current_page || 0}/#{status.total_pages || "?"}
        Movies Found: #{status.movies_found}
        Movies Imported: #{status.movies_imported}
        Movies Failed: #{status.movies_failed}
        Import Rate: #{status.rate} movies/min
        Duration: #{duration_str}
        Started: #{status.started_at}
        ----------------------------------------
        """)
      end)
    end
    
    # Also show Oban queue status
    import Ecto.Query
    alias Cinegraph.Repo
    
    queue_stats = Repo.all(
      from j in Oban.Job,
      group_by: [j.queue, j.state],
      select: {j.queue, j.state, count(j.id)}
    )
    
    if length(queue_stats) > 0 do
      Logger.info("\nOban Queue Status:")
      Enum.group_by(queue_stats, fn {queue, _, _} -> queue end)
      |> Enum.each(fn {queue, stats} ->
        Logger.info("  #{queue}:")
        Enum.each(stats, fn {_, state, count} ->
          Logger.info("    #{state}: #{count}")
        end)
      end)
    end
    
  "pause" ->
    id = List.last(args)
    if id do
      case Integer.parse(id) do
        {progress_id, _} ->
          case Cinegraph.Imports.TMDbImporter.pause_import(progress_id) do
            {:ok, progress} ->
              Logger.info("✅ Import #{progress_id} paused successfully")
            {:error, :not_found} ->
              Logger.error("❌ Import #{progress_id} not found")
            {:error, {:invalid_status, status}} ->
              Logger.error("❌ Cannot pause import with status: #{status}")
          end
        _ ->
          Logger.error("❌ Invalid import ID: #{id}")
      end
    else
      Logger.error("❌ Please provide an import ID to pause")
    end
    
  "resume" ->
    id = List.last(args)
    if id do
      case Integer.parse(id) do
        {progress_id, _} ->
          case Cinegraph.Imports.TMDbImporter.resume_import(progress_id) do
            {:ok, progress} ->
              Logger.info("✅ Import #{progress_id} resumed successfully")
            {:error, :not_found} ->
              Logger.error("❌ Import #{progress_id} not found")
            {:error, {:invalid_status, status}} ->
              Logger.error("❌ Cannot resume import with status: #{status}")
          end
        _ ->
          Logger.error("❌ Invalid import ID: #{id}")
      end
    else
      Logger.error("❌ Please provide an import ID to resume")
    end
    
  _ ->
    Logger.error("Unknown command: #{command}")
    Logger.error("Run with --help to see available commands")
end
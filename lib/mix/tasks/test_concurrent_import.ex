defmodule Mix.Tasks.TestConcurrentImport do
  @moduledoc """
  Test the new concurrent import system.
  
  Usage:
    mix test_concurrent_import [type] [pages]
    
  Examples:
    mix test_concurrent_import                  # Defaults to popular, 10 pages
    mix test_concurrent_import top_rated 20     # Top rated movies, 20 pages
    mix test_concurrent_import popular 100      # Popular movies, 100 pages
  """
  use Mix.Task
  
  @shortdoc "Test concurrent movie import"
  
  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")
    
    {import_type, pages} = case args do
      [type, pages_str] -> 
        {type, String.to_integer(pages_str)}
      [type] -> 
        {type, 10}
      [] -> 
        {"popular", 10}
    end
    
    IO.puts("\n🚀 Starting concurrent import test")
    IO.puts("Type: #{import_type}")
    IO.puts("Pages: #{pages}")
    IO.puts("Expected movies: ~#{pages * 20}")
    IO.puts("")
    
    case Cinegraph.Import.ImportCoordinator.start_import(import_type, pages) do
      {:ok, import_id} ->
        IO.puts("✅ Import started successfully!")
        IO.puts("Import ID: #{import_id}")
        IO.puts("")
        IO.puts("Monitor progress at: http://localhost:4000/import")
        IO.puts("")
        
        # Monitor for a bit to show initial progress
        monitor_import(import_id, 30)
        
      {:error, reason} ->
        IO.puts("❌ Failed to start import: #{inspect(reason)}")
    end
  end
  
  defp monitor_import(_import_id, 0), do: :ok
  defp monitor_import(import_id, remaining_checks) do
    Process.sleep(2000)
    
    case Cinegraph.Import.ImportStats.get_stats(import_id) do
      {:ok, stats} ->
        IO.puts("\r📊 Progress: #{stats.pages_processed}/#{stats.total_pages} pages | " <>
                "#{stats.movies_imported} movies | " <>
                "#{stats.current_rate} movies/min | " <>
                "#{Float.round((stats.pages_processed / stats.total_pages) * 100, 1)}% complete")
        
        if stats.status == :completed do
          IO.puts("\n\n✅ Import completed!")
          IO.puts("Total movies imported: #{stats.movies_imported}")
          IO.puts("Total time: #{DateTime.diff(stats.last_updated, stats.started_at, :second)} seconds")
        else
          monitor_import(import_id, remaining_checks - 1)
        end
        
      {:error, :not_found} ->
        IO.puts("\n❌ Import stats not found. Import may have completed or failed.")
    end
  end
end
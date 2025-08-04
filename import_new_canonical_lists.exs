# Script to import the new canonical lists
alias Cinegraph.Workers.CanonicalImportOrchestrator

IO.puts("=== Importing New Canonical Lists ===\n")

# Lists to import
lists_to_import = [
  {"sight_sound_critics_2022", "BFI's Sight & Sound Critics' Top 100 (2022)"},
  {"national_film_registry", "National Film Registry"}
]

# Queue each import
Enum.each(lists_to_import, fn {list_key, display_name} ->
  IO.puts("Queueing import for: #{display_name}")
  
  job_args = %{
    "action" => "orchestrate_import",
    "list_key" => list_key
  }
  
  case CanonicalImportOrchestrator.new(job_args) |> Oban.insert() do
    {:ok, job} ->
      IO.puts("✅ Successfully queued #{display_name} (Job ID: #{job.id})")
      
    {:error, reason} ->
      IO.puts("❌ Failed to queue #{display_name}: #{inspect(reason)}")
  end
end)

IO.puts("\n=== Import Jobs Queued ===")
IO.puts("\nMonitor progress:")
IO.puts("- Oban Dashboard: http://localhost:4001/dev/oban")
IO.puts("- Check status: mix run check_canonical_import_status.exs")
IO.puts("\nExpected:")
IO.puts("- Sight & Sound: ~100 movies")
IO.puts("- National Film Registry: ~900 movies")
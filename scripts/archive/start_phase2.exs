IO.puts("=== Starting Phase 2: Systematic Import Test ===\n")

# Start the import
IO.puts("Starting full import...")

case Cinegraph.Imports.TMDbImporter.start_full_import() do
  {:ok, info} ->
    IO.puts("\nImport started!")
    IO.puts("  Starting from page: #{info.starting_page}")
    IO.puts("  TMDB total: #{info.tmdb_total} movies")
    IO.puts("  Our current total: #{info.our_total} movies")

    IO.puts("\n📊 Monitor progress at: http://localhost:4000/imports")
    IO.puts("🔍 Run 'mix run monitor_import.exs' to check detailed status")
    IO.puts("\nThe import will continue automatically in the background.")
    IO.puts("Target: 10,000 movies (~500 pages, ~5-6 hours)")

  {:error, reason} ->
    IO.puts("\n❌ Failed to start import: #{inspect(reason)}")
    System.halt(1)
end

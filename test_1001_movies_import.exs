# Test 1001 Movies import to see failed IMDb lookups
alias Cinegraph.Workers.CanonicalImportOrchestrator

IO.puts("Starting 1001 Movies import to test failed IMDb lookups...")

# Clear any existing failed lookups to see fresh results
Cinegraph.Repo.delete_all(Cinegraph.Movies.FailedImdbLookup)
IO.puts("Cleared existing failed lookups")

# Trigger the import
job_args = %{
  "action" => "orchestrate_import",
  "list_key" => "1001_movies"
}

case CanonicalImportOrchestrator.new(job_args) |> Oban.insert() do
  {:ok, job} ->
    IO.puts("Successfully queued 1001 Movies import")
    IO.puts("Job ID: #{job.id}")
    IO.puts("\nMonitor failed TMDb lookups with:")
    IO.puts("SELECT state, args FROM oban_jobs WHERE worker = 'Cinegraph.Workers.TMDbDetailsWorker' AND state IN ('retryable', 'discarded') ORDER BY inserted_at DESC LIMIT 10;")
    IO.puts("\nCheck failed lookups with:")
    IO.puts("SELECT * FROM failed_imdb_lookups;")
    
  {:error, reason} ->
    IO.puts("Failed to queue import: #{inspect(reason)}")
end
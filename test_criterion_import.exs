# Test Criterion Collection import with enhanced debugging
alias Cinegraph.Workers.CanonicalImportOrchestrator

# Trigger the import
job_args = %{
  "action" => "orchestrate_import",
  "list_key" => "criterion"
}

case CanonicalImportOrchestrator.new(job_args) |> Oban.insert() do
  {:ok, job} ->
    IO.puts("Successfully queued Criterion Collection import")
    IO.puts("Job ID: #{job.id}")
    IO.puts("\nMonitor logs with: mix phx.server")
    IO.puts("Or check debug HTML files with: ls criterion_worker_*.html")
    
  {:error, reason} ->
    IO.puts("Failed to queue import: #{inspect(reason)}")
end
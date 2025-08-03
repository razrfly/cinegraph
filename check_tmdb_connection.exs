# Check TMDb connection health and retry failed jobs

IO.puts("=== TMDb Connection Health Check ===\n")

# Test basic connection
IO.puts("1. Testing TMDb API connection...")
case Cinegraph.Services.TMDb.Client.get("/configuration") do
  {:ok, _} ->
    IO.puts("   ✅ API connection successful")
  {:error, reason} ->
    IO.puts("   ❌ API connection failed: #{inspect(reason)}")
end

# Check rate limiter status
IO.puts("\n2. Rate limiter status:")
try do
  rate_limit_status = :ets.lookup(:rate_limiter, :tmdb)
  IO.inspect(rate_limit_status, label: "   Rate limit tokens")
rescue
  _ -> IO.puts("   Rate limiter not initialized")
end

# Check failed jobs
import Ecto.Query
alias Cinegraph.Repo

failed_jobs = Repo.all(
  from j in Oban.Job,
  where: j.state == "retryable" and j.queue == "tmdb_details",
  order_by: [desc: j.scheduled_at],
  limit: 10
)

IO.puts("\n3. Failed TMDb details jobs: #{length(failed_jobs)}")
Enum.each(failed_jobs, fn job ->
  IO.puts("   - TMDb ID: #{job.args["tmdb_id"]} - Attempt: #{job.attempt}/#{job.max_attempts}")
  if job.errors != [] do
    latest_error = List.last(job.errors)
    IO.puts("     Error: #{inspect(latest_error["error"])}")
  end
end)

# Retry specific job for "The Northman"
IO.puts("\n4. Retrying 'The Northman' (TMDb ID: 639933)...")
northman_job = Repo.one(
  from j in Oban.Job,
  where: j.queue == "tmdb_details" and 
         j.args["tmdb_id"] == 639933 and
         j.state == "retryable",
  order_by: [desc: j.id],
  limit: 1
)

if northman_job do
  # Cancel the failed job and create a new one
  Oban.cancel_job(northman_job.id)
  
  # Insert a fresh job
  %{"tmdb_id" => 639933}
  |> Cinegraph.Workers.TMDbDetailsWorker.new()
  |> Oban.insert()
  |> case do
    {:ok, job} ->
      IO.puts("   ✅ Created new job: #{job.id}")
    {:error, reason} ->
      IO.puts("   ❌ Failed to create job: #{inspect(reason)}")
  end
else
  IO.puts("   ℹ️  No retryable job found for The Northman")
end

# Test fetching the movie directly
IO.puts("\n5. Testing direct fetch of The Northman...")
case Cinegraph.Services.TMDb.get_movie(639933) do
  {:ok, movie} ->
    IO.puts("   ✅ Direct fetch successful: #{movie["title"]}")
  {:error, reason} ->
    IO.puts("   ❌ Direct fetch failed: #{inspect(reason)}")
end
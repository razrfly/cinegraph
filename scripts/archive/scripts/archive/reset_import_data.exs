# Reset all import data for a fresh start
alias Cinegraph.Repo
import Ecto.Query

IO.puts("Resetting import data...")

# Clear all import state
Repo.delete_all(Cinegraph.Imports.ImportState)
IO.puts("✓ Cleared import state")

# Clear all jobs
Repo.delete_all(Oban.Job)
IO.puts("✓ Cleared all Oban jobs")

# Clear all movie-related data using direct table names
Repo.delete_all("movie_credits")
Repo.delete_all("movie_videos")
Repo.delete_all("movie_release_dates")
Repo.delete_all("external_ratings")

# Clear junction tables
Repo.delete_all("movie_genres")
Repo.delete_all("movie_keywords")
Repo.delete_all("movie_production_companies")

# Clear the main tables
Repo.delete_all(Cinegraph.Movies.Movie)
Repo.delete_all(Cinegraph.Movies.Person)
Repo.delete_all(Cinegraph.Movies.Genre)
Repo.delete_all(Cinegraph.Movies.Keyword)
Repo.delete_all(Cinegraph.Movies.ProductionCompany)

IO.puts("✓ Cleared all movie data")

# Verify everything is empty
movie_count = Repo.aggregate(Cinegraph.Movies.Movie, :count)
person_count = Repo.aggregate(Cinegraph.Movies.Person, :count)
job_count = Repo.aggregate(Oban.Job, :count)

IO.puts("\nVerification:")
IO.puts("  Movies: #{movie_count}")
IO.puts("  People: #{person_count}")
IO.puts("  Jobs: #{job_count}")

IO.puts("\n✅ All data cleared\! Ready for fresh import.")

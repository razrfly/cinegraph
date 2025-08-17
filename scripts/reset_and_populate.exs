#!/usr/bin/env elixir
# Reset and populate database with comprehensive movie data
# Usage: elixir scripts/reset_and_populate.exs [options]
#
# Options:
#   --pages N    Number of pages to import (default: 10 = 200 movies)
#   --skip-drop  Skip database drop/create (just clear data)
#   --dry-run    Show what would be done without doing it

defmodule ResetAndPopulate do
  def run(args \\ []) do
    {opts, _, _} = OptionParser.parse(args,
      switches: [
        pages: :integer,
        skip_drop: :boolean,
        dry_run: :boolean
      ]
    )
    
    pages = opts[:pages] || 10
    skip_drop = opts[:skip_drop] || false
    dry_run = opts[:dry_run] || false
    
    IO.puts("🎬 Cinegraph Database Reset and Populate")
    IO.puts("=" <> String.duplicate("=", 60))
    IO.puts("Pages to import: #{pages} (~#{pages * 20} movies)")
    IO.puts("Skip drop/create: #{skip_drop}")
    IO.puts("Dry run: #{dry_run}")
    IO.puts("")
    
    if dry_run do
      IO.puts("🔍 DRY RUN MODE - No changes will be made")
      IO.puts("")
    end
    
    unless skip_drop do
      step("Dropping existing database", dry_run, fn ->
        Mix.Task.run("ecto.drop", ["--quiet"])
      end)
      
      step("Creating fresh database", dry_run, fn ->
        Mix.Task.run("ecto.create", ["--quiet"])
      end)
      
      step("Running migrations", dry_run, fn ->
        Mix.Task.run("ecto.migrate", ["--quiet"])
      end)
    end
    
    step("Starting application", dry_run, fn ->
      Mix.Task.run("app.start")
    end)
    
    step("Importing #{pages * 20} movies with comprehensive data", dry_run, fn ->
      Mix.Task.run("import_movies", ["--fresh", "--pages", "#{pages}"])
    end)
    
    unless dry_run do
      print_summary()
    end
    
    IO.puts("\n✅ Complete!")
  end
  
  defp step(description, dry_run, func) do
    IO.write("#{description}... ")
    
    if dry_run do
      IO.puts("[WOULD RUN]")
    else
      try do
        func.()
        IO.puts("✅")
      rescue
        e ->
          IO.puts("❌")
          IO.puts("Error: #{inspect(e)}")
          System.halt(1)
      end
    end
  end
  
  defp print_summary do
    IO.puts("\n📊 Database Summary:")
    
    # Only try to query if app is started and not in dry run
    try do
      movies = Cinegraph.Repo.aggregate(Cinegraph.Movies.Movie, :count, :id)
      keywords = Cinegraph.Repo.aggregate(Cinegraph.Movies.Keyword, :count, :id)
      videos = Cinegraph.Repo.aggregate(Cinegraph.Movies.MovieVideo, :count, :id)
      credits = Cinegraph.Repo.aggregate(Cinegraph.Movies.Credit, :count, :id)
      ratings = Cinegraph.Repo.aggregate(Cinegraph.ExternalSources.Rating, :count, :id)
      
      IO.puts("  Movies: #{movies}")
      IO.puts("  Keywords: #{keywords}")
      IO.puts("  Videos: #{videos}")
      IO.puts("  Credits: #{credits}")
      IO.puts("  External Ratings: #{ratings}")
    rescue
      _ ->
        IO.puts("  (Unable to query database)")
    end
  end
end

# Run the script
ResetAndPopulate.run(System.argv())
defmodule Mix.Tasks.SeedMovieLists do
  @moduledoc """
  Seeds the database with default movie lists from canonical_lists.ex
  
  Usage:
      mix seed_movie_lists
  """
  use Mix.Task
  
  require Logger

  @shortdoc "Seeds movie lists from hardcoded canonical lists"
  
  def run(_args) do
    Mix.Task.run("app.start")
    
    Logger.info("Seeding movie lists from canonical lists...")
    
    result = Cinegraph.Movies.MovieLists.migrate_hardcoded_lists()
    
    IO.puts("""
    
    Movie Lists Seeding Results:
    ============================
      Created: #{result.created} new lists
      Already existed: #{result.existed} lists
      Errors: #{length(result.errors)}
      Total processed: #{result.total}
    """)
    
    if length(result.errors) > 0 do
      IO.puts("\nErrors occurred:")
      Enum.each(result.errors, fn {:error, source_key, changeset} ->
        IO.puts("  - #{source_key}: #{inspect(changeset.errors)}")
      end)
    end
    
    IO.puts("\nSeeding completed!")
  end
end
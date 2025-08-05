# Test updating statistics directly
require Logger

# Get the list
list = Cinegraph.Movies.MovieLists.get_by_source_key("1001_movies")

if list do
  IO.puts("Found list: #{list.name}")
  IO.puts("Current stats:")
  IO.puts("  Last Import: #{list.last_import_at || "Never"}")
  IO.puts("  Movie Count: #{list.last_movie_count}")
  IO.puts("  Status: #{list.last_import_status || "None"}")
  IO.puts("  Total Imports: #{list.total_imports}")
  
  # Count actual movies
  import Ecto.Query
  count = Cinegraph.Repo.one(
    from m in Cinegraph.Movies.Movie,
    where: fragment("? \\? ?", m.canonical_sources, "1001_movies"),
    select: count(m.id)
  )
  IO.puts("\nActual movies in database: #{count}")
  
  # Update the stats directly
  IO.puts("\nUpdating stats...")
  case Cinegraph.Movies.MovieLists.update_import_stats(list, "success", count) do
    {:ok, updated_list} ->
      IO.puts("✓ Successfully updated!")
      IO.puts("\nNew stats:")
      IO.puts("  Last Import: #{updated_list.last_import_at}")
      IO.puts("  Movie Count: #{updated_list.last_movie_count}")
      IO.puts("  Status: #{updated_list.last_import_status}")
      IO.puts("  Total Imports: #{updated_list.total_imports}")
      
    {:error, changeset} ->
      IO.puts("✗ Failed to update: #{inspect(changeset.errors)}")
  end
else
  IO.puts("List not found!")
end
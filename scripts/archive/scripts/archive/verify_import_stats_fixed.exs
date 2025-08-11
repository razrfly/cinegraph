# Comprehensive test to verify import statistics are now working
require Logger

IO.puts("\n" <> String.duplicate("=", 60))
IO.puts("VERIFYING IMPORT STATISTICS FIX")
IO.puts(String.duplicate("=", 60) <> "\n")

# 1. Check current state of 1001_movies list
IO.puts("1. CHECKING CURRENT STATE")
IO.puts(String.duplicate("-", 40))
list = Cinegraph.Movies.MovieLists.get_by_source_key("1001_movies")

if list do
  IO.puts("List: #{list.name}")
  IO.puts("  Last Import: #{list.last_import_at || "Never"}")
  IO.puts("  Movie Count: #{list.last_movie_count}")
  IO.puts("  Status: #{list.last_import_status || "None"}")
  IO.puts("  Total Imports: #{list.total_imports}")

  # Count actual movies
  import Ecto.Query

  actual_count =
    Cinegraph.Repo.one(
      from m in Cinegraph.Movies.Movie,
        where: fragment("? \\? ?", m.canonical_sources, "1001_movies"),
        select: count(m.id)
    )

  IO.puts("  Actual Movies in DB: #{actual_count}")

  if list.last_movie_count == actual_count && list.last_import_at != nil do
    IO.puts("\n✅ IMPORT STATISTICS ARE WORKING!")
    IO.puts("The fix has been successfully applied.")
  else
    IO.puts("\n⚠️  Statistics may be out of sync")
    IO.puts("You may need to run another import to see the fix in action")
  end
else
  IO.puts("❌ List not found!")
end

# 2. Test other lists
IO.puts("\n2. CHECKING OTHER LISTS")
IO.puts(String.duplicate("-", 40))

other_lists = [
  "criterion",
  "sight_sound_critics_2022",
  "national_film_registry",
  "cannes_winners"
]

Enum.each(other_lists, fn key ->
  list = Cinegraph.Movies.MovieLists.get_by_source_key(key)

  if list do
    status = if list.last_import_at, do: "✓ Imported", else: "○ Not imported"
    IO.puts("#{status} #{key}: #{list.last_movie_count} movies")
  end
end)

# 3. Show how to trigger a new import
IO.puts("\n3. HOW TO TEST NEW IMPORT")
IO.puts(String.duplicate("-", 40))
IO.puts("To test that statistics update on new imports:")
IO.puts("1. Go to http://localhost:4001/import")
IO.puts("2. Select a list that hasn't been imported (○ marked above)")
IO.puts("3. Click 'Import/Update List'")
IO.puts("4. Watch the 'Last Import' and 'Movies' columns update")
IO.puts("\nOr run: mix import_canonical --list criterion")

IO.puts("\n✅ Verification complete!")

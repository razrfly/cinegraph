# Script to seed default movie lists into the database
# Run with: mix run priv/repo/migrate_movie_lists.exs

require Logger

Logger.info("Seeding default movie lists...")

result = Cinegraph.Movies.MovieLists.seed_default_lists()

Logger.info("Migration complete!")
Logger.info("Created: #{result.created} lists")
Logger.info("Already existed: #{result.existed} lists")

if length(result.errors) > 0 do
  Logger.error("Errors occurred:")
  Enum.each(result.errors, fn {:error, source_key, changeset} ->
    Logger.error("Failed to create #{source_key}: #{inspect(changeset.errors)}")
  end)
end

# Verify the migration
Logger.info("\nVerifying migration - All movie lists in database:")
Cinegraph.Movies.MovieLists.list_all_movie_lists()
|> Enum.each(fn list ->
  Logger.info("  - #{list.name} (#{list.source_key}) - #{list.source_type}: #{list.source_id}")
end)
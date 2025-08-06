# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs
#
# Inside the script, you can read and write to any of your
# repositories directly:
#
#     Cinegraph.Repo.insert!(%Cinegraph.SomeSchema{})
#
# We recommend using the bang functions (`insert!`, `update!`
# and so on) as they will fail if something goes wrong.

require Logger

Logger.info("Running seeds...")

# Seed movie lists from hardcoded canonical lists
Logger.info("Seeding movie lists from canonical lists...")
result = Cinegraph.Movies.MovieLists.migrate_hardcoded_lists()

Logger.info("""
Movie Lists Seeding Results:
  - Created: #{result.created}
  - Already existed: #{result.existed}
  - Errors: #{length(result.errors)}
  - Total processed: #{result.total}
""")

if length(result.errors) > 0 do
  Logger.warning("Errors occurred during seeding:")

  Enum.each(result.errors, fn {:error, source_key, changeset} ->
    Logger.warning("  - #{source_key}: #{inspect(changeset.errors)}")
  end)
end

Logger.info("Seeds completed!")

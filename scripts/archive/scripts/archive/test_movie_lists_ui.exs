# Test script for the updated movie lists UI
# Run with: mix run test_movie_lists_ui.exs

require Logger

Logger.info("Testing Movie Lists UI Updates...")

# Test 1: Create a test list to show in UI
Logger.info("\n1. Creating test list for UI demo:")

test_attrs = %{
  source_key: "test_ui_list",
  name: "Test UI List - Can Delete",
  source_type: "imdb",
  source_url: "https://www.imdb.com/list/ls111111111/",
  source_id: "ls111111111",
  category: "personal",
  active: true,
  description: "This is a test list created to demo the UI"
}

case Cinegraph.Movies.MovieLists.create_movie_list(test_attrs) do
  {:ok, list} ->
    Logger.info("  ✓ Created test list: #{list.name} (ID: #{list.id})")
    Logger.info("  ✓ This list will appear in the UI and can be edited/deleted")

  {:error, changeset} ->
    Logger.info("  ℹ Test list already exists or error: #{inspect(changeset.errors)}")
end

# Test 2: Show current lists
Logger.info("\n2. Current movie lists in database:")
lists = Cinegraph.Movies.MovieLists.list_all_movie_lists()

Enum.each(lists, fn list ->
  status = if list.active, do: "Active", else: "Inactive"
  Logger.info("  - #{list.name} (#{status}) - #{list.category}")
end)

Logger.info("\n✅ Movie Lists UI test complete!")
Logger.info("\nYou can now:")
Logger.info("1. Go to http://localhost:4001/import")
Logger.info("2. Click '+ Add New List' button to open the modal")
Logger.info("3. Edit any list by clicking 'Edit'")
Logger.info("4. Delete the test list by clicking 'Delete'")
Logger.info("5. Enable/Disable lists with the toggle button")

# Test script for the new movie lists system
# Run with: mix run test_movie_lists.exs

require Logger

Logger.info("Testing Movie Lists System...")

# Test 1: Check that all hardcoded lists are in the database
Logger.info("\n1. Checking database lists:")
db_lists = Cinegraph.Movies.MovieLists.list_all_movie_lists()
Logger.info("Found #{length(db_lists)} lists in database")

Enum.each(db_lists, fn list ->
  Logger.info("  - #{list.name} (#{list.source_key}) - #{list.source_type}: #{list.source_id}")
end)

# Test 2: Test get_config function with fallback
Logger.info("\n2. Testing get_config with fallback:")
test_keys = ["1001_movies", "criterion", "fake_list"]

Enum.each(test_keys, fn key ->
  case Cinegraph.Movies.MovieLists.get_config(key) do
    {:ok, config} ->
      Logger.info("  ✓ #{key}: Found config - #{config.name}")
    {:error, reason} ->
      Logger.info("  ✗ #{key}: Not found - #{reason}")
  end
end)

# Test 3: Test available_lists function
Logger.info("\n3. Testing available_lists function:")
available = Cinegraph.Workers.CanonicalImportOrchestrator.available_lists()
Logger.info("Total available lists: #{map_size(available)}")

# Test 4: Create a test list
Logger.info("\n4. Testing list creation:")
test_attrs = %{
  source_key: "test_list_#{:os.system_time(:second)}",
  name: "Test Movie List",
  source_type: "imdb",
  source_url: "https://www.imdb.com/list/ls999999999/",
  source_id: "ls999999999",
  category: "personal",
  active: true,
  description: "This is a test list"
}

case Cinegraph.Movies.MovieLists.create_movie_list(test_attrs) do
  {:ok, list} ->
    Logger.info("  ✓ Created test list: #{list.name} (ID: #{list.id})")
    
    # Test updating it
    case Cinegraph.Movies.MovieLists.update_movie_list(list, %{active: false}) do
      {:ok, updated} ->
        Logger.info("  ✓ Updated list active status to: #{updated.active}")
      {:error, _} ->
        Logger.info("  ✗ Failed to update list")
    end
    
    # Clean up
    case Cinegraph.Movies.MovieLists.delete_movie_list(list) do
      {:ok, _} ->
        Logger.info("  ✓ Deleted test list")
      {:error, _} ->
        Logger.info("  ✗ Failed to delete test list")
    end
    
  {:error, changeset} ->
    Logger.error("  ✗ Failed to create test list: #{inspect(changeset.errors)}")
end

Logger.info("\n✅ Movie Lists System test complete!")
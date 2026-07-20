defmodule Cinegraph.Services.TMDb.DailyExportTest do
  use ExUnit.Case, async: true

  alias Cinegraph.Services.TMDb.DailyExport

  setup do
    dir = Path.join(System.tmp_dir!(), "daily_export_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  # Writes a file and stamps its mtime so newest-2 ordering is deterministic.
  defp seed(dir, name, age_seconds) do
    path = Path.join(dir, name)
    File.write!(path, "{}")
    mtime = System.os_time(:second) - age_seconds
    File.touch!(path, mtime)
    path
  end

  describe "prune_old_exports/2 (#1120)" do
    test "keeps only the newest 2 matching exports, deletes older ones", %{dir: dir} do
      newest = seed(dir, "movie_ids_07_20_2026.json", 0)
      second = seed(dir, "movie_ids_07_19_2026.json", 100)
      third = seed(dir, "movie_ids_07_18_2026.json", 200)
      fourth = seed(dir, "movie_ids_07_17_2026.json", 300)

      DailyExport.prune_old_exports(dir, "movie_ids_*.json")

      assert File.exists?(newest)
      assert File.exists?(second)
      refute File.exists?(third)
      refute File.exists?(fourth)
    end

    test "does not touch person exports when pruning movie exports", %{dir: dir} do
      seed(dir, "movie_ids_07_20_2026.json", 0)
      seed(dir, "movie_ids_07_19_2026.json", 100)
      seed(dir, "movie_ids_07_18_2026.json", 200)
      person = seed(dir, "person_ids_07_18_2026.json", 999)

      DailyExport.prune_old_exports(dir, "movie_ids_*.json")

      assert File.exists?(person)
    end

    test "never matches the .gz (already removed after decompression)", %{dir: dir} do
      gz = seed(dir, "movie_ids_07_18_2026.json.gz", 999)
      seed(dir, "movie_ids_07_20_2026.json", 0)
      seed(dir, "movie_ids_07_19_2026.json", 100)
      seed(dir, "movie_ids_07_18_2026.json", 200)

      DailyExport.prune_old_exports(dir, "movie_ids_*.json")

      assert File.exists?(gz)
    end

    test "is a no-op when 2 or fewer exports exist", %{dir: dir} do
      a = seed(dir, "person_ids_07_20_2026.json", 0)
      b = seed(dir, "person_ids_07_19_2026.json", 100)

      DailyExport.prune_old_exports(dir, "person_ids_*.json")

      assert File.exists?(a)
      assert File.exists?(b)
    end
  end
end

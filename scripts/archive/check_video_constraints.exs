#!/usr/bin/env elixir
# Check unique constraints on movie_videos table

Mix.start()
Mix.shell(Mix.Shell.Process)
{:ok, _} = Application.ensure_all_started(:cinegraph)

alias Cinegraph.Repo

IO.puts("\n=== Checking unique constraints on movie_videos table ===\n")

# Check all constraints
result = Repo.query!("""
  SELECT conname, contype 
  FROM pg_constraint 
  WHERE conrelid = 'movie_videos'::regclass
""")

IO.puts("All constraints on movie_videos table:")
Enum.each(result.rows, fn [name, type] ->
  type_desc = case type do
    "p" -> "PRIMARY KEY"
    "u" -> "UNIQUE"
    "f" -> "FOREIGN KEY"
    "c" -> "CHECK"
    _ -> type
  end
  IO.puts("  #{name}: #{type_desc}")
end)

# Check unique indexes
IO.puts("\n\nAll indexes on movie_videos table:")
index_result = Repo.query!("""
  SELECT indexname, indexdef
  FROM pg_indexes 
  WHERE tablename = 'movie_videos'
""")

Enum.each(index_result.rows, fn [name, def] ->
  IO.puts("  #{name}")
  IO.puts("    #{def}")
end)

# Check columns
IO.puts("\n\nColumns in movie_videos table:")
column_result = Repo.query!("""
  SELECT column_name 
  FROM information_schema.columns 
  WHERE table_name = 'movie_videos'
  ORDER BY ordinal_position
""")

Enum.each(column_result.rows, fn [name] ->
  IO.puts("  #{name}")
end)
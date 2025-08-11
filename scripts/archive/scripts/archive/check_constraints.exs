#!/usr/bin/env elixir
# Check unique constraints on movies table

Mix.start()
Mix.shell(Mix.Shell.Process)
{:ok, _} = Application.ensure_all_started(:cinegraph)

alias Cinegraph.Repo

IO.puts("\n=== Checking unique constraints on movies table ===\n")

# Check all constraints
result = Repo.query!("""
  SELECT conname, contype 
  FROM pg_constraint 
  WHERE conrelid = 'movies'::regclass
""")

IO.puts("All constraints on movies table:")
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
IO.puts("\n\nUnique indexes on movies table:")
index_result = Repo.query!("""
  SELECT indexname 
  FROM pg_indexes 
  WHERE tablename = 'movies' 
  AND indexdef LIKE '%UNIQUE%'
""")

Enum.each(index_result.rows, fn [name] ->
  IO.puts("  #{name}")
end)

# Check the specific conflict target issue
IO.puts("\n\nChecking for unique constraint/index on (tmdb_id):")
tmdb_result = Repo.query!("""
  SELECT conname 
  FROM pg_constraint 
  WHERE conrelid = 'movies'::regclass 
  AND contype = 'u'
  AND conkey = ARRAY(
    SELECT attnum FROM pg_attribute 
    WHERE attrelid = 'movies'::regclass 
    AND attname = 'tmdb_id'
  )
""")

if length(tmdb_result.rows) > 0 do
  IO.puts("  Found: #{inspect(tmdb_result.rows)}")
else
  IO.puts("  No unique constraint on tmdb_id found!")
end
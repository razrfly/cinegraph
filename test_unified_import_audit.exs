# Audit the unified festival import problem
IO.puts(String.duplicate("=", 80))
IO.puts("UNIFIED FESTIVAL IMPORT AUDIT")
IO.puts(String.duplicate("=", 80))

# Check what tables exist
IO.puts("\n1. DATABASE TABLE STATUS:")
IO.puts(String.duplicate("-", 40))

{:ok, result} = Cinegraph.Repo.query("""
  SELECT table_name, 
         (SELECT COUNT(*) FROM information_schema.tables WHERE table_name = t.table_name) as exists
  FROM (VALUES 
    ('oscar_ceremonies'),
    ('oscar_categories'),
    ('oscar_nominations'),
    ('festival_organizations'),
    ('festival_ceremonies'),
    ('festival_categories'),
    ('festival_nominations')
  ) AS t(table_name)
""")

Enum.each(result.rows, fn [table, exists] ->
  status = if exists == 1, do: "✓ EXISTS", else: "✗ MISSING"
  IO.puts("  #{String.pad_trailing(table, 25)} #{status}")
end)

# Check data counts
IO.puts("\n2. DATA COUNTS:")
IO.puts(String.duplicate("-", 40))

tables = [
  "oscar_ceremonies",
  "oscar_categories", 
  "oscar_nominations",
  "festival_organizations",
  "festival_ceremonies",
  "festival_categories",
  "festival_nominations"
]

Enum.each(tables, fn table ->
  case Cinegraph.Repo.query("SELECT COUNT(*) FROM #{table}") do
    {:ok, %{rows: [[count]]}} ->
      IO.puts("  #{String.pad_trailing(table, 25)} #{count} rows")
    {:error, _} ->
      IO.puts("  #{String.pad_trailing(table, 25)} ERROR")
  end
end)

# Check the import flow
IO.puts("\n3. IMPORT FLOW ANALYSIS:")
IO.puts(String.duplicate("-", 40))

IO.puts("\nThe OscarImportWorker calls:")
IO.puts("  → Cultural.import_oscar_year(year)")
IO.puts("    → fetch_or_create_ceremony(year)")
IO.puts("      → Looks in oscar_ceremonies table (OLD)")
IO.puts("      → If not found, fetches from OscarScraper")
IO.puts("      → Inserts into oscar_ceremonies (OLD)")
IO.puts("    → UnifiedOscarImporter.import_ceremony(ceremony)")
IO.puts("      → Expects ceremony from oscar_ceremonies")
IO.puts("      → Creates data in festival_* tables (NEW)")

IO.puts("\n4. THE PROBLEM:")
IO.puts(String.duplicate("-", 40))
IO.puts("❌ fetch_or_create_ceremony still uses OLD oscar_ceremonies table")
IO.puts("❌ UnifiedOscarImporter depends on data existing in OLD tables first")
IO.puts("❌ We're not REPLACING the old tables, we're MIGRATING from them")
IO.puts("❌ But there's no data in old tables to migrate from!")

IO.puts("\n5. WHAT SHOULD HAPPEN (Per Issue #152):")
IO.puts(String.duplicate("-", 40))
IO.puts("✓ Fetch Oscar data directly from scraper")
IO.puts("✓ Insert directly into festival_* tables (NEW)")
IO.puts("✓ Skip oscar_* tables entirely")
IO.puts("✓ Dashboard queries from festival_* tables")

IO.puts("\n6. REQUIRED FIXES:")
IO.puts(String.duplicate("-", 40))
IO.puts("1. Cultural.import_oscar_year should:")
IO.puts("   - NOT use fetch_or_create_ceremony (which uses old tables)")
IO.puts("   - Fetch directly from OscarScraper")
IO.puts("   - Pass raw data to UnifiedOscarImporter")
IO.puts("")
IO.puts("2. UnifiedOscarImporter should:")
IO.puts("   - Accept raw ceremony data from scraper")
IO.puts("   - NOT expect data from oscar_ceremonies table")
IO.puts("   - Create everything in festival_* tables")
IO.puts("")
IO.puts("3. Dashboard should:")
IO.puts("   - Query from festival_* tables (ALREADY DONE)")
IO.puts("")

IO.puts("\n" <> String.duplicate("=", 80))
IO.puts("CONCLUSION: The import does nothing because it's trying to")
IO.puts("migrate from empty oscar_* tables instead of importing fresh")
IO.puts("data directly into the new festival_* tables.")
IO.puts(String.duplicate("=", 80))
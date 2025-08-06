# \!/usr/bin/env elixir

# Test script for the new unified festival import system

IO.puts("\n" <> String.duplicate("=", 60))
IO.puts("🎬 UNIFIED FESTIVAL IMPORT SYSTEM TEST")
IO.puts(String.duplicate("=", 60))

IO.puts("\n📋 Available festivals:")
IO.puts("  - cannes   : Cannes Film Festival")
IO.puts("  - bafta    : BAFTA Film Awards")
IO.puts("  - berlin   : Berlin International Film Festival")
IO.puts("  - venice   : Venice International Film Festival")

IO.puts("\n📝 Example commands to test the system:")
IO.puts("")

# Single festival, single year
IO.puts("1️⃣  Import Cannes 2024:")
IO.puts("    Cinegraph.Cultural.import_festival(\"cannes\", 2024)")
IO.puts("")

IO.puts("2️⃣  Import BAFTA 2024:")
IO.puts("    Cinegraph.Cultural.import_festival(\"bafta\", 2024)")
IO.puts("")

IO.puts("3️⃣  Import Berlin 2024:")
IO.puts("    Cinegraph.Cultural.import_festival(\"berlin\", 2024)")
IO.puts("")

# Multiple years for a single festival
IO.puts("4️⃣  Import Cannes 2020-2024:")
IO.puts("    Cinegraph.Cultural.import_festival_years(\"cannes\", 2020..2024)")
IO.puts("")

# All festivals for a specific year
IO.puts("5️⃣  Import ALL festivals for 2024:")
IO.puts("    Cinegraph.Cultural.import_all_festivals_for_year(2024)")
IO.puts("")

# Check status
IO.puts("6️⃣  Check import status:")
IO.puts("    Cinegraph.Cultural.get_festival_import_status()")
IO.puts("    Cinegraph.Cultural.get_festival_import_status(\"cannes\")")
IO.puts("")

IO.puts(String.duplicate("-", 60))
IO.puts("\n🚀 Let's test importing ALL festivals for 2024...")
IO.puts("")

result = Cinegraph.Cultural.import_all_festivals_for_year(2024)

case result do
  {:ok, stats} ->
    IO.puts("✅ SUCCESS\! Jobs queued for all festivals")
    IO.puts("   Year: #{stats.year}")
    IO.puts("   Festivals: #{Enum.join(stats.festivals, ", ")}")
    IO.puts("   Jobs queued: #{stats.jobs}")
    IO.puts("   Status: #{stats.status}")

    IO.puts("\n⏳ Waiting 5 seconds to check job status...")
    Process.sleep(5000)

    IO.puts("\n📊 Import Status:")
    status = Cinegraph.Cultural.get_festival_import_status()
    IO.puts("   Running: #{status.running_jobs}")
    IO.puts("   Queued: #{status.queued_jobs}")
    IO.puts("   Completed: #{status.completed_jobs}")
    IO.puts("   Failed: #{status.failed_jobs}")

  {:error, reason} ->
    IO.puts("❌ ERROR: #{inspect(reason)}")
end

IO.puts("\n" <> String.duplicate("=", 60))
IO.puts("🎉 Test complete\! Check the database for imported festivals.")
IO.puts(String.duplicate("=", 60))

# Test script for unified festival import
require Logger

IO.puts("\n=== Testing Unified Festival Import ===\n")

# Test 1: Import Oscar data for 2024
IO.puts("1. Testing Oscar import for 2024...")

# Get the Oscar organization
oscar_org = Cinegraph.Festivals.get_organization_by_abbreviation("AMPAS")
IO.inspect(oscar_org, label: "Oscar Organization")

# Get a single Oscar ceremony
oscar_ceremony = Cinegraph.Cultural.list_oscar_ceremonies() 
                |> Enum.find(& &1.year == 2024)

if oscar_ceremony do
  IO.puts("\nImporting 2024 Oscar ceremony...")
  result = Cinegraph.Festivals.UnifiedOscarImporter.import_ceremony(oscar_ceremony, oscar_org)
  IO.inspect(result, label: "Import Result")
  
  # Check what was created
  Process.sleep(1000)
  
  # Get stats
  stats = Cinegraph.Festivals.UnifiedOscarImporter.import_stats()
  IO.inspect(stats, label: "Oscar Stats in Unified Structure")
  
  # Check some nominations
  import Ecto.Query
  sample_nominations = Cinegraph.Repo.all(
    from n in Cinegraph.Festivals.FestivalNomination,
    join: c in assoc(n, :ceremony),
    join: cat in assoc(n, :category),
    join: m in assoc(n, :movie),
    where: c.organization_id == ^oscar_org.id and c.year == 2024,
    limit: 5,
    select: %{
      movie: m.title,
      category: cat.name,
      won: n.won,
      prize: n.prize_name,
      details: n.details
    }
  )
  
  IO.puts("\nSample nominations:")
  Enum.each(sample_nominations, fn nom ->
    winner = if nom.won, do: "WINNER", else: "Nominee"
    IO.puts("  #{nom.movie} - #{nom.category} (#{winner})")
    if nom.details["nominee_names"] do
      IO.puts("    Person: #{nom.details["nominee_names"]}")
    end
  end)
else
  IO.puts("No 2024 ceremony found!")
end

IO.puts("\n" <> String.duplicate("=", 50) <> "\n")

# Test 2: Check festival organizations
IO.puts("2. Checking all festival organizations...")
orgs = Cinegraph.Festivals.list_organizations()
Enum.each(orgs, fn org ->
  IO.puts("  #{org.abbreviation}: #{org.name} (#{org.country}, founded #{org.founded_year})")
end)

IO.puts("\n" <> String.duplicate("=", 50) <> "\n")

# Test 3: Count nominations by organization
IO.puts("3. Counting nominations by organization...")
counts = Cinegraph.Festivals.count_nominations_by_organization()
IO.inspect(counts, label: "Nomination Counts")

IO.puts("\n=== Test Complete ===\n")
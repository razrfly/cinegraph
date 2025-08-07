alias Cinegraph.Scrapers.UnifiedFestivalScraper
alias Cinegraph.Events
alias Cinegraph.Events.FestivalEventCache

# Test the caching behavior more thoroughly
IO.puts("\n=== Deep Cache Analysis ===")

# 1. Check the cache state
IO.puts("\n1. Cache state:")
try do
  events = FestivalEventCache.get_active_events()
  IO.puts("  Cache has #{length(events)} events")
  cannes = Enum.find(events, fn e -> e.source_key == "cannes" end)
  new_horizons = Enum.find(events, fn e -> e.source_key == "new_horizons" end)
  
  if cannes do
    IO.puts("  ✅ Cannes found: #{cannes.abbreviation}, id=#{cannes.id}")
  else
    IO.puts("  ❌ Cannes NOT in cache!")
  end
  
  if new_horizons do
    IO.puts("  ✅ New Horizons found: #{new_horizons.abbreviation}, id=#{new_horizons.id}")
  else
    IO.puts("  ❌ New Horizons NOT in cache!")
  end
rescue
  e -> IO.puts("  ❌ Cache error: #{inspect(e)}")
end

# 2. Test the lookup function used during parsing
IO.puts("\n2. Testing find_by_abbreviation (used in parsing):")
["CFF", "NHIFF", "VIFF", "BIFF"] |> Enum.each(fn abbr ->
  event = FestivalEventCache.find_by_abbreviation(abbr)
  if event do
    IO.puts("  ✅ #{abbr}: #{event.name}")
  else
    IO.puts("  ❌ #{abbr}: Not found!")
  end
end)

# 3. Simulate what happens during HTML parsing
IO.puts("\n3. Simulating parser lookup:")

# Create a fake festival config like the parser uses
cannes_config = %{
  abbreviation: "CFF",
  name: "Cannes Film Festival"
}

nh_config = %{
  abbreviation: "NHIFF", 
  name: "New Horizons"
}

# This is what get_festival_event_by_config does
cannes_event = FestivalEventCache.find_by_abbreviation(cannes_config.abbreviation)
nh_event = FestivalEventCache.find_by_abbreviation(nh_config.abbreviation)

IO.puts("  Cannes lookup (CFF): #{if cannes_event, do: "✅ Found", else: "❌ NOT FOUND"}")
IO.puts("  New Horizons lookup (NHIFF): #{if nh_event, do: "✅ Found", else: "❌ NOT FOUND"}")

if cannes_event do
  IO.puts("    metadata: #{inspect(cannes_event.metadata)}")
end

if nh_event do
  IO.puts("    metadata: #{inspect(nh_event.metadata)}")
end
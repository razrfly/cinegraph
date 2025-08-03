# Test script for Oscar scraper
# Run with: mix run test_oscar_scraper.exs

require Logger

# First, let's try the direct fetch approach (might fail due to 403)
Logger.info("Testing Oscar scraper...")
Logger.info("=" <> String.duplicate("=", 50))

# Test 1: Try fetching directly from Oscars.org
Logger.info("\nTest 1: Attempting direct fetch from Oscars.org for 2023...")
case Cinegraph.Cultural.import_oscar_ceremony(2023) do
  {:ok, ceremony} ->
    Logger.info("✅ Successfully imported ceremony!")
    Logger.info("Ceremony ID: #{ceremony.id}")
    Logger.info("Year: #{ceremony.year}")
    Logger.info("Ceremony Number: #{ceremony.ceremony_number}")
    Logger.info("Data keys: #{inspect(Map.keys(ceremony.data))}")
    
  {:error, reason} ->
    Logger.warn("❌ Direct fetch failed (expected): #{inspect(reason)}")
end

# Test 2: Create sample HTML to test parsing
Logger.info("\nTest 2: Testing HTML parsing with sample data...")

# Sample HTML that mimics Oscars.org structure based on oscar_data patterns
sample_html = """
<html>
<body>
  <h1>96th Academy Awards</h1>
  
  <div class="awards-result-chron">
    <div class="result-group-header">Best Picture</div>
    <div class="result-subgroup winner">
      <div class="result-details">
        Oppenheimer - Christopher Nolan, Emma Thomas and Charles Roven, Producers
      </div>
    </div>
    <div class="result-subgroup">
      <div class="result-details">
        Barbie - David Heyman, Margot Robbie, Tom Ackerley and Robbie Brenner, Producers
      </div>
    </div>
  </div>
  
  <div class="awards-result-chron">
    <div class="result-group-header">Best Director</div>
    <div class="result-subgroup winner">
      <div class="result-details">
        Christopher Nolan - Oppenheimer
      </div>
    </div>
    <div class="result-subgroup">
      <div class="result-details">
        Martin Scorsese - Killers of the Flower Moon
      </div>
    </div>
  </div>
  
  <div class="awards-result-chron">
    <div class="result-group-header">Best Actor</div>
    <div class="result-subgroup winner">
      <div class="result-details">
        Cillian Murphy - Oppenheimer
      </div>
    </div>
  </div>
</body>
</html>
"""

# Write sample HTML to a temporary file
temp_file = "/tmp/oscar_2024_sample.html"
File.write!(temp_file, sample_html)

# Import from file
case Cinegraph.Cultural.import_oscar_ceremony_from_file(temp_file, 2024) do
  {:ok, ceremony} ->
    Logger.info("✅ Successfully parsed and imported sample ceremony!")
    Logger.info("Ceremony ID: #{ceremony.id}")
    Logger.info("Year: #{ceremony.year}")
    Logger.info("Ceremony Number: #{ceremony.ceremony_number}")
    Logger.info("\nParsed data structure:")
    Logger.info(Jason.encode!(ceremony.data, pretty: true))
    
  {:error, reason} ->
    Logger.error("❌ Failed to parse sample HTML: #{inspect(reason)}")
end

# Test 3: Check what we have in the database
Logger.info("\nTest 3: Checking stored ceremonies...")
ceremonies = Cinegraph.Cultural.list_oscar_ceremonies()
Logger.info("Total ceremonies in database: #{length(ceremonies)}")

Enum.each(ceremonies, fn ceremony ->
  category_count = length(ceremony.data["categories"] || [])
  Logger.info("- Year #{ceremony.year} (#{ceremony.ceremony_number}th): #{category_count} categories")
end)

Logger.info("\n" <> String.duplicate("=", 50))
Logger.info("Test complete!")
Logger.info("\nNext steps:")
Logger.info("1. Manually download HTML from https://www.oscars.org/oscars/ceremonies/2024")
Logger.info("2. Save as 'oscar_2024.html'")
Logger.info("3. Import with: Cinegraph.Cultural.import_oscar_ceremony_from_file(\"oscar_2024.html\", 2024)")
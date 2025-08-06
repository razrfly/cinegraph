ceremony = Cinegraph.Repo.get(Cinegraph.Festivals.FestivalCeremony, 50)
IO.puts("\n=== Ceremony Enhancement Status ===")
IO.puts("Has imdb_matched flag: #{ceremony.data["imdb_matched"] == true}")

# Check a sample nominee for IMDb data
categories = ceremony.data["categories"] || []
if length(categories) > 0 do
  first_cat = List.first(categories)
  nominees = first_cat["nominees"] || []
  if length(nominees) > 1 do
    # Check second nominee (first one has IMDb ID)
    second_nominee = Enum.at(nominees, 1)
    IO.puts("\n=== Sample Nominee (#{second_nominee["film"]}) ===")
    IO.puts("Has film_imdb_id: #{second_nominee["film_imdb_id"] != nil}")
    IO.puts("film_imdb_id value: #{inspect(second_nominee["film_imdb_id"])}")
  end
end

# Force re-enhancement
IO.puts("\n=== Attempting Re-enhancement ===")
temp_ceremony = %{year: ceremony.year, data: ceremony.data}

try do
  case Cinegraph.Scrapers.ImdbOscarScraper.enhance_ceremony_with_imdb(temp_ceremony) do
    {:ok, enhanced_data} ->
      IO.puts("✅ Enhancement successful")
      
      # Count IMDb IDs in enhanced data
      categories = enhanced_data["categories"] || []
      all_nominees = Enum.flat_map(categories, fn cat -> cat["nominees"] || [] end)
      with_imdb = Enum.count(all_nominees, fn nom ->
        imdb_id = nom["film_imdb_id"]
        imdb_id != nil and imdb_id != ""
      end)
      
      IO.puts("Nominees with IMDb IDs after enhancement: #{with_imdb}/#{length(all_nominees)}")
      
      # Calculate coverage percentage
      total_nominees = length(all_nominees)
      coverage = if total_nominees > 0, do: with_imdb / total_nominees, else: 0
      
      # Only update if we have good coverage (>95%)
      if coverage >= 0.95 do
        IO.puts("\n=== Updating Ceremony with Enhanced Data ===")
        IO.puts("Coverage: #{Float.round(coverage * 100, 1)}% (#{with_imdb}/#{total_nominees})")
        changeset = Cinegraph.Festivals.FestivalCeremony.changeset(ceremony, %{data: enhanced_data})
        case Cinegraph.Repo.update(changeset) do
          {:ok, _updated} -> 
            IO.puts("✅ Ceremony updated with enhanced data")
          {:error, reason} ->
            IO.puts("❌ Failed to update: #{inspect(reason)}")
        end
      else
        IO.puts("\n⚠️ Insufficient IMDb coverage: #{Float.round(coverage * 100, 1)}% (#{with_imdb}/#{total_nominees})")
        IO.puts("Skipping update - need at least 95% coverage")
      end
      
    {:error, reason} ->
      IO.puts("❌ Enhancement failed: #{inspect(reason)}")
  end
rescue
  e -> 
    IO.puts("❌ Exception during enhancement: #{inspect(e)}")
end
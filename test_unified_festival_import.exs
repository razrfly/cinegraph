# Test the unified festival import flow
# This ensures data goes into festival_* tables instead of oscar_* tables

IO.puts("Testing unified festival import...")

# Step 1: Check we have the festival_organizations table
oscar_org = Cinegraph.Festivals.get_or_create_oscar_organization()
IO.puts("✅ Oscar organization created/found: #{oscar_org.name} (ID: #{oscar_org.id})")

# Step 2: Import a test Oscar year (2024)
IO.puts("\nImporting Oscar data for 2024...")
case Cinegraph.Cultural.import_oscar_year(2024) do
  {:ok, result} ->
    IO.puts("✅ Oscar import queued:")
    IO.inspect(result)
    
    # Wait for job to process
    IO.puts("\nWaiting 5 seconds for job to process...")
    Process.sleep(5000)
    
    # Step 3: Check that data is in festival tables
    import Ecto.Query
    
    # Check festival_ceremonies
    ceremony_count = Cinegraph.Repo.aggregate(
      from(c in Cinegraph.Festivals.FestivalCeremony, 
        where: c.organization_id == ^oscar_org.id),
      :count
    )
    IO.puts("\n📊 Festival ceremonies for Oscars: #{ceremony_count}")
    
    # Check festival_categories
    category_count = Cinegraph.Repo.aggregate(
      from(c in Cinegraph.Festivals.FestivalCategory, 
        where: c.organization_id == ^oscar_org.id),
      :count
    )
    IO.puts("📊 Festival categories for Oscars: #{category_count}")
    
    # Check festival_nominations
    nomination_count = Cinegraph.Repo.aggregate(
      from(n in Cinegraph.Festivals.FestivalNomination,
        join: cer in Cinegraph.Festivals.FestivalCeremony, on: n.ceremony_id == cer.id,
        where: cer.organization_id == ^oscar_org.id),
      :count
    )
    IO.puts("📊 Festival nominations for Oscars: #{nomination_count}")
    
  {:error, reason} ->
    IO.puts("❌ Failed to import Oscar data: #{inspect(reason)}")
end

IO.puts("\n✨ Test complete! Data should now be in festival_* tables instead of oscar_* tables.")
# Test Venice import with association fix
IO.puts("Testing Venice import with association fix...")

result = Cinegraph.Cultural.import_venice_year(2024)
IO.inspect(result, label: "Venice Import Result")

# Wait for job to process
IO.puts("\nWaiting for job to process...")
Process.sleep(10000)

# Check job status
import Ecto.Query

job =
  Cinegraph.Repo.one(
    from(j in Oban.Job,
      where: j.worker == "Cinegraph.Workers.VeniceFestivalWorker",
      order_by: [desc: j.id],
      limit: 1
    )
  )

if job do
  IO.puts("\n📊 Latest Job Status: #{job.state}")

  case job.state do
    "completed" ->
      IO.puts("✅ SUCCESS! Venice import completed")

      # Check for ceremony and nominations
      venice_org = Cinegraph.Festivals.get_organization_by_abbreviation("VIFF")

      if venice_org do
        ceremony = Cinegraph.Festivals.get_ceremony_by_year(venice_org.id, 2024)

        if ceremony do
          IO.puts("\n🎬 Venice 2024 Ceremony Found!")
          awards = ceremony.data["awards"] || %{}
          IO.puts("Award categories: #{map_size(awards)}")

          # Check for nominations created
          nomination_count =
            Cinegraph.Repo.one(
              from(n in Cinegraph.Festivals.FestivalNomination,
                where: n.ceremony_id == ^ceremony.id,
                select: count(n.id)
              )
            )

          IO.puts("Nominations created: #{nomination_count}")

          # Show sample nominations
          sample_nominations =
            Cinegraph.Repo.all(
              from(n in Cinegraph.Festivals.FestivalNomination,
                join: c in Cinegraph.Festivals.FestivalCategory,
                on: n.category_id == c.id,
                where: n.ceremony_id == ^ceremony.id,
                limit: 5,
                select: %{
                  category: c.name,
                  won: n.won,
                  details: n.details
                }
              )
            )

          IO.puts("\n=== Sample Nominations ===")

          Enum.each(sample_nominations, fn nom ->
            film_title = nom.details["film_title"]
            winner_status = if nom.won, do: "🏆 WINNER", else: "Nominee"
            IO.puts("#{nom.category}: #{film_title} (#{winner_status})")
          end)
        else
          IO.puts("❌ No ceremony found for Venice 2024")
        end
      else
        IO.puts("❌ Venice organization not found")
      end

    state when state in ["failed", "discarded"] ->
      IO.puts("❌ Job failed")

      if job.errors && length(job.errors) > 0 do
        IO.puts("Errors:")

        Enum.each(job.errors, fn error ->
          IO.puts("  #{inspect(error)}")
        end)
      end

    other_state ->
      IO.puts("⏳ Job still in state: #{other_state}")
  end
else
  IO.puts("❌ No Venice job found")
end

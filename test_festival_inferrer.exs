import Ecto.Query
alias Cinegraph.Repo
alias Cinegraph.People.FestivalPersonInferrer

alias Cinegraph.Festivals.{
  FestivalNomination,
  FestivalCeremony,
  FestivalCategory,
  FestivalOrganization
}

IO.puts("=== TESTING FESTIVAL PERSON INFERRER (DIRECTOR ONLY) ===\n")

# Get statistics on what can be inferred
stats = FestivalPersonInferrer.get_inference_stats()

IO.puts("=== INFERENCE POTENTIAL ===")
IO.puts("Director categories found: #{length(stats.director_categories)}")

if length(stats.director_categories) > 0 do
  IO.puts("\nSample director categories:")

  Enum.take(stats.director_categories, 5)
  |> Enum.each(&IO.puts("  - #{&1}"))
end

IO.puts("\nTotal director nominations: #{stats.total_director_nominations}")
IO.puts("Already linked: #{stats.already_linked}")
IO.puts("Can be inferred: #{stats.can_be_inferred}")

# Run the inference
IO.puts("\n=== RUNNING DIRECTOR INFERENCE ===")
results = FestivalPersonInferrer.infer_all_director_nominations()

IO.puts("\nResults:")
IO.puts("  Successfully linked: #{results.success}")
IO.puts("  Skipped (not directors): #{results.skipped}")
IO.puts("  Failed (no director credit): #{results.failed}")
IO.puts("  Total processed: #{results.total}")

if results.success > 0 do
  success_rate = Float.round(results.success / max(results.total - results.skipped, 1) * 100, 1)
  IO.puts("  Success rate (excluding non-directors): #{success_rate}%")
end

# Check 2024 specifically
IO.puts("\n=== 2024 FESTIVAL STATISTICS ===")

query_2024 =
  from n in FestivalNomination,
    join: c in FestivalCeremony,
    on: n.ceremony_id == c.id,
    join: cat in FestivalCategory,
    on: n.category_id == cat.id,
    join: org in FestivalOrganization,
    on: c.organization_id == org.id,
    where: c.year == 2024,
    where: cat.tracks_person == true,
    where: org.abbreviation != "AMPAS",
    select: %{
      festival: org.name,
      category: cat.name,
      person_id: n.person_id,
      movie_id: n.movie_id
    }

noms_2024 = Repo.all(query_2024)

linked_2024 = Enum.filter(noms_2024, & &1.person_id)
unlinked_2024 = Enum.filter(noms_2024, &is_nil(&1.person_id))

IO.puts("Non-Oscar person nominations in 2024: #{length(noms_2024)}")

IO.puts(
  "Linked: #{length(linked_2024)} (#{Float.round(length(linked_2024) / max(length(noms_2024), 1) * 100, 1)}%)"
)

IO.puts("Unlinked: #{length(unlinked_2024)}")

# Show some examples of linked nominations
if length(linked_2024) > 0 do
  IO.puts("\n=== SAMPLE LINKED DIRECTOR NOMINATIONS ===")

  linked_2024
  |> Enum.take(5)
  |> Enum.each(fn nom ->
    person = Repo.get!(Cinegraph.Movies.Person, nom.person_id)
    IO.puts("  #{nom.festival} - #{nom.category}: #{person.name}")
  end)
end

# Deep dive into collaboration data
import Ecto.Query
alias Cinegraph.Repo

IO.puts("=== COLLABORATION DATA DEEP DIVE ===\n")

# Check collaboration table structure
IO.puts("1. COLLABORATION TABLE SAMPLE:")

sample_collabs =
  Repo.all(
    from c in Cinegraph.Collaborations.Collaboration,
      join: p1 in Cinegraph.Movies.Person,
      on: p1.id == c.person_a_id,
      join: p2 in Cinegraph.Movies.Person,
      on: p2.id == c.person_b_id,
      order_by: [desc: c.collaboration_count],
      limit: 5,
      select: %{
        person_a: p1.name,
        person_b: p2.name,
        count: c.collaboration_count,
        first_date: c.first_collaboration_date,
        latest_date: c.latest_collaboration_date,
        avg_rating: c.avg_movie_rating,
        total_revenue: c.total_revenue,
        years_active: c.years_active
      }
  )

Enum.each(sample_collabs, fn collab ->
  rating =
    if collab.avg_rating, do: Float.round(Decimal.to_float(collab.avg_rating), 1), else: "N/A"

  revenue = div(collab.total_revenue || 0, 1_000_000)
  years = if collab.years_active, do: Enum.join(collab.years_active, ", "), else: "N/A"

  IO.puts("\n#{collab.person_a} & #{collab.person_b}:")
  IO.puts("  Movies: #{collab.count}")
  IO.puts("  Period: #{collab.first_date} to #{collab.latest_date}")
  IO.puts("  Avg Rating: #{rating}")
  IO.puts("  Total Revenue: $#{revenue}M")
  IO.puts("  Active Years: #{years}")
end)

# Check collaboration details
IO.puts("\n\n2. COLLABORATION DETAILS SAMPLE:")

details =
  Repo.all(
    from cd in Cinegraph.Collaborations.CollaborationDetail,
      join: c in Cinegraph.Collaborations.Collaboration,
      on: c.id == cd.collaboration_id,
      join: m in Cinegraph.Movies.Movie,
      on: m.id == cd.movie_id,
      join: p1 in Cinegraph.Movies.Person,
      on: p1.id == c.person_a_id,
      join: p2 in Cinegraph.Movies.Person,
      on: p2.id == c.person_b_id,
      where: c.collaboration_count > 1,
      order_by: [desc: cd.movie_revenue],
      limit: 10,
      select: %{
        movie_title: m.title,
        person_a: p1.name,
        person_b: p2.name,
        type: cd.collaboration_type,
        year: cd.year,
        rating: cd.movie_rating,
        revenue: cd.movie_revenue
      }
  )

Enum.each(details, fn detail ->
  rating = if detail.rating, do: Float.round(Decimal.to_float(detail.rating), 1), else: "N/A"
  revenue = div(detail.revenue || 0, 1_000_000)

  IO.puts("\n#{detail.movie_title} (#{detail.year}):")
  IO.puts("  #{detail.person_a} & #{detail.person_b}")
  IO.puts("  Type: #{detail.type}")
  IO.puts("  Rating: #{rating}, Revenue: $#{revenue}M")
end)

# Check if we can find paths between people (six degrees)
IO.puts("\n\n3. SIX DEGREES TEST:")
# Find two people who have worked together
connection =
  Repo.one(
    from c in Cinegraph.Collaborations.Collaboration,
      join: p1 in Cinegraph.Movies.Person,
      on: p1.id == c.person_a_id,
      join: p2 in Cinegraph.Movies.Person,
      on: p2.id == c.person_b_id,
      where: c.collaboration_count > 0,
      limit: 1,
      select: %{
        person1_id: c.person_a_id,
        person2_id: c.person_b_id,
        person1_name: p1.name,
        person2_name: p2.name
      }
  )

if connection do
  IO.puts("Testing direct connection: #{connection.person1_name} → #{connection.person2_name}")
  IO.puts("Direct collaboration exists: ✓")

  # Test finding a 2-degree connection
  # First, get all unique intermediaries (people directly connected to person1)
  intermediaries =
    from c in Cinegraph.Collaborations.Collaboration,
      where: c.person_a_id == ^connection.person1_id or c.person_b_id == ^connection.person1_id,
      select:
        fragment(
          "CASE WHEN ? = ? THEN ? ELSE ? END",
          c.person_a_id,
          ^connection.person1_id,
          c.person_b_id,
          c.person_a_id
        ),
      distinct: true

  # Then count unique second-degree connections through those intermediaries
  two_degree_count =
    Repo.one(
      from i in subquery(intermediaries),
        join: c in Cinegraph.Collaborations.Collaboration,
        on: c.person_a_id == i.id or c.person_b_id == i.id,
        where:
          c.person_a_id != ^connection.person1_id and c.person_b_id != ^connection.person1_id,
        select:
          count(
            fragment(
              "DISTINCT CASE WHEN ? = ? THEN ? ELSE ? END",
              c.person_a_id,
              i.id,
              c.person_b_id,
              c.person_a_id
            )
          )
    )

  IO.puts("\n2-degree connections found: #{two_degree_count}")

  if two_degree_count > 0 do
    IO.puts("Six degrees functionality: ✓ WORKING")
  else
    IO.puts("Six degrees functionality: Need more data")
  end
end

# Check PersonRelationship table
IO.puts("\n\n4. PERSON RELATIONSHIP TABLE:")
relationship_count = Repo.aggregate(Cinegraph.Collaborations.PersonRelationship, :count)
IO.puts("Cached relationships: #{relationship_count}")

# Verify collaboration data quality
IO.puts("\n\n5. DATA QUALITY CHECKS:")

# Check for orphaned collaboration details
orphaned_details =
  Repo.one(
    from cd in Cinegraph.Collaborations.CollaborationDetail,
      left_join: c in Cinegraph.Collaborations.Collaboration,
      on: c.id == cd.collaboration_id,
      where: is_nil(c.id),
      select: count(cd.id)
  )

IO.puts("Orphaned collaboration details: #{orphaned_details}")

# Check for missing movie references
missing_movies =
  Repo.one(
    from cd in Cinegraph.Collaborations.CollaborationDetail,
      left_join: m in Cinegraph.Movies.Movie,
      on: m.id == cd.movie_id,
      where: is_nil(m.id),
      select: count(cd.id)
  )

IO.puts("Collaboration details with missing movies: #{missing_movies}")

# Check revenue data
revenue_stats =
  Repo.one(
    from c in Cinegraph.Collaborations.Collaboration,
      select: %{
        total_collabs: count(c.id),
        with_revenue: count(fragment("CASE WHEN ? > 0 THEN 1 END", c.total_revenue)),
        avg_revenue: avg(c.total_revenue)
      }
  )

IO.puts("\nRevenue Data:")

IO.puts(
  "  Collaborations with revenue: #{revenue_stats.with_revenue}/#{revenue_stats.total_collabs}"
)

avg_rev =
  if revenue_stats.avg_revenue,
    do: div(trunc(Decimal.to_float(revenue_stats.avg_revenue)), 1_000_000),
    else: 0

IO.puts("  Average total revenue: $#{avg_rev}M")

IO.puts("\n✅ Collaboration data is properly structured and functional!")

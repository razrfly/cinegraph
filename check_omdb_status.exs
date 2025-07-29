defmodule CheckOMDbStatus do
  alias Cinegraph.Repo
  alias Cinegraph.Movies.Movie
  import Ecto.Query
  
  def run do
    IO.puts("\n📊 OMDb DATA STATUS CHECK\n")
    IO.puts(String.duplicate("=", 60))
    
    # Get counts
    total_movies = Repo.aggregate(Movie, :count)
    
    movies_with_imdb = Repo.one(
      from m in Movie,
      where: not is_nil(m.imdb_id),
      select: count(m.id)
    )
    
    movies_with_omdb = Repo.one(
      from m in Movie,
      where: not is_nil(m.omdb_data),
      select: count(m.id)
    )
    
    movies_missing_omdb = Repo.one(
      from m in Movie,
      where: not is_nil(m.imdb_id) and is_nil(m.omdb_data),
      select: count(m.id)
    )
    
    # Calculate percentages
    omdb_coverage = if total_movies > 0, do: Float.round(movies_with_omdb / total_movies * 100, 1), else: 0.0
    potential_coverage = if total_movies > 0, do: Float.round(movies_with_imdb / total_movies * 100, 1), else: 0.0
    
    # Print results
    IO.puts("Total movies: #{total_movies}")
    IO.puts("Movies with IMDb ID: #{movies_with_imdb} (#{potential_coverage}%)")
    IO.puts("Movies with OMDb data: #{movies_with_omdb} (#{omdb_coverage}%)")
    IO.puts("Movies missing OMDb data: #{movies_missing_omdb}")
    
    if movies_missing_omdb > 0 do
      IO.puts("\n⏱️  Estimated time to complete: #{div(movies_missing_omdb, 60)} minutes #{rem(movies_missing_omdb, 60)} seconds")
      IO.puts("   (Based on 1 API call per second)")
      
      # Show sample of missing movies
      IO.puts("\n📋 Sample of movies missing OMDb data:")
      
      Repo.all(
        from m in Movie,
        where: not is_nil(m.imdb_id) and is_nil(m.omdb_data),
        order_by: [desc: m.popularity],
        limit: 10,
        select: {m.title, m.imdb_id}
      )
      |> Enum.each(fn {title, imdb_id} ->
        IO.puts("   - #{title} (#{imdb_id})")
      end)
      
      IO.puts("\n💡 To complete the enrichment, run:")
      IO.puts("   source .env && mix import_movies --enrich --api omdb")
    else
      IO.puts("\n✅ All movies with IMDb IDs have OMDb data!")
    end
    
    # Check for successful extractions
    IO.puts("\n📈 OMDb Field Extraction Success:")
    
    movies_with_awards = Repo.one(
      from m in Movie,
      where: not is_nil(m.awards_text) and m.awards_text != "N/A",
      select: count(m.id)
    )
    
    movies_with_box_office = Repo.one(
      from m in Movie,
      where: not is_nil(m.box_office_domestic),
      select: count(m.id)
    )
    
    IO.puts("   - Awards text: #{movies_with_awards} movies")
    IO.puts("   - Box office: #{movies_with_box_office} movies")
  end
end

CheckOMDbStatus.run()
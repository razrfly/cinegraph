defmodule Mix.Tasks.ImportMovies do
  use Mix.Task
  
  alias Cinegraph.Importers.ComprehensiveMovieImporter
  
  @shortdoc "Import movies from TMDb and enrich with OMDb data"
  
  @moduledoc """
  Import movies from TMDb and enrich with OMDb data.
  
  ## Usage
  
      # Import 5 pages of popular movies (default)
      mix import_movies
      
      # Import specific number of pages
      mix import_movies --pages 10
      
      # Import specific TMDb IDs
      mix import_movies --ids 550,551,552
      
      # Enrich existing movies with OMDb data
      mix import_movies --enrich
      
      # Fresh start - clear all data first
      mix import_movies --fresh
  """
  
  def run(args) do
    Mix.Task.run("app.start")
    
    {opts, _, _} = OptionParser.parse(args,
      switches: [
        pages: :integer,
        ids: :string,
        enrich: :boolean,
        fresh: :boolean
      ]
    )
    
    cond do
      opts[:fresh] ->
        clear_data()
        import_pages(opts[:pages] || 5)
        
      opts[:enrich] ->
        ComprehensiveMovieImporter.enrich_existing_movies_with_omdb()
        
      opts[:ids] ->
        ids = opts[:ids]
        |> String.split(",")
        |> Enum.map(&String.to_integer/1)
        
        ComprehensiveMovieImporter.import_specific_movies(ids)
        
      true ->
        import_pages(opts[:pages] || 5)
    end
  end
  
  defp import_pages(pages) do
    Mix.shell().info("Importing #{pages} pages of popular movies...")
    ComprehensiveMovieImporter.import_popular_movies(pages)
  end
  
  defp clear_data do
    Mix.shell().info("Clearing existing data...")
    
    # Clear in order to respect foreign keys
    Cinegraph.Repo.query!("TRUNCATE external_ratings CASCADE")
    Cinegraph.Repo.query!("TRUNCATE movie_list_items CASCADE")
    Cinegraph.Repo.query!("TRUNCATE movie_credits CASCADE")
    Cinegraph.Repo.query!("TRUNCATE movie_keywords CASCADE")
    Cinegraph.Repo.query!("TRUNCATE movie_production_companies CASCADE")
    Cinegraph.Repo.query!("TRUNCATE movie_videos CASCADE")
    Cinegraph.Repo.query!("TRUNCATE movie_release_dates CASCADE")
    Cinegraph.Repo.query!("TRUNCATE movie_alternative_titles CASCADE")
    Cinegraph.Repo.query!("TRUNCATE movie_translations CASCADE")
    Cinegraph.Repo.query!("TRUNCATE movies CASCADE")
    
    Mix.shell().info("Data cleared!")
  end
end
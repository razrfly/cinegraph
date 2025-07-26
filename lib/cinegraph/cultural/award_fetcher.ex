defmodule Cinegraph.Cultural.AwardFetcher do
  @moduledoc """
  Fetches and stores real award data from external sources.
  """

  alias Cinegraph.{Repo, Cultural, Movies}
  alias Cinegraph.Cultural.CuratedList
  alias Cinegraph.Services.Wikidata
  
  require Logger

  @doc """
  Fetches and stores award data for a movie.
  """
  def fetch_and_store_awards(movie) do
    if movie.imdb_id do
      Logger.info("Fetching awards for #{movie.title} (IMDb: #{movie.imdb_id})")
      
      case Wikidata.fetch_movie_awards(movie.imdb_id) do
        {:ok, awards} ->
          store_awards(movie, awards)
          {:ok, length(awards)}
        {:error, reason} ->
          Logger.error("Failed to fetch awards for #{movie.title}: #{inspect(reason)}")
          {:error, reason}
      end
    else
      Logger.warning("Movie #{movie.title} has no IMDb ID - cannot fetch awards")
      {:error, :no_imdb_id}
    end
  end

  @doc """
  Fetches awards for all movies in the database.
  """
  def fetch_all_movie_awards do
    movies = Movies.list_movies()
    
    results = Enum.map(movies, fn movie ->
      # Add delay to avoid rate limiting
      Process.sleep(1000)
      
      case fetch_and_store_awards(movie) do
        {:ok, count} -> 
          IO.puts("✅ #{movie.title}: #{count} awards")
          {:ok, movie.id}
        {:error, reason} -> 
          IO.puts("❌ #{movie.title}: #{inspect(reason)}")
          {:error, movie.id, reason}
      end
    end)
    
    successful = Enum.count(results, &match?({:ok, _}, &1))
    failed = Enum.count(results, &match?({:error, _, _}, &1))
    
    IO.puts("\nSummary: #{successful} successful, #{failed} failed")
    results
  end

  # Private functions

  defp store_awards(movie, awards) do
    # Group awards by authority
    awards_by_authority = Enum.group_by(awards, &award_to_authority_name/1)
    
    Enum.each(awards_by_authority, fn {authority_name, award_list} ->
      # Get or create the authority
      authority = case Cultural.get_authority_by_name(authority_name) do
        nil -> 
          # Create if doesn't exist
          {:ok, auth} = Cultural.create_authority(%{
            name: authority_name,
            authority_type: "award",
            category: "film_award",
            trust_score: default_trust_score(authority_name),
            base_weight: 1.5,
            data_source: "wikidata"
          })
          auth
        existing -> 
          existing
      end
      
      # Group by year to create appropriate lists
      awards_by_year = Enum.group_by(award_list, & &1.year)
      
      Enum.each(awards_by_year, fn {year, year_awards} ->
        list_name = if year, do: "#{authority_name} #{year}", else: authority_name
        
        # Get or create the curated list for this authority/year
        list = get_or_create_award_list(authority, list_name, year)
        
        # Add movie to the list with award details
        Enum.each(year_awards, fn award ->
          attrs = %{
            movie_id: movie.id,
            list_id: list.id,
            award_category: award.category,
            award_result: award.result,
            notes: build_award_notes(award)
          }
          
          # Remove from list first to avoid duplicates
          Cultural.remove_movie_from_list(movie.id, list.id, award.category)
          
          # Add with award details
          case Cultural.add_movie_to_list(movie.id, list.id, attrs) do
            {:ok, _} -> :ok
            {:error, changeset} -> 
              Logger.error("Failed to add movie to list: #{inspect(changeset.errors)}")
          end
        end)
      end)
    end)
  end

  defp award_to_authority_name(%{award_name: name}) do
    cond do
      String.contains?(name, "Academy Award") -> "Academy of Motion Picture Arts and Sciences"
      String.contains?(name, "Oscar") -> "Academy of Motion Picture Arts and Sciences"
      String.contains?(name, "Golden Globe") -> "Golden Globe Awards"
      String.contains?(name, "BAFTA") -> "British Academy Film Awards"
      String.contains?(name, "Cannes") -> "Cannes Film Festival"
      String.contains?(name, "Berlin") -> "Berlin International Film Festival"
      String.contains?(name, "Venice") -> "Venice Film Festival"
      String.contains?(name, "Sundance") -> "Sundance Film Festival"
      true -> name
    end
  end

  defp default_trust_score(authority_name) do
    cond do
      String.contains?(authority_name, "Academy") -> 9.5
      String.contains?(authority_name, "Golden Globe") -> 8.5
      String.contains?(authority_name, "BAFTA") -> 8.5
      String.contains?(authority_name, "Cannes") -> 9.0
      String.contains?(authority_name, "Berlin") -> 8.5
      String.contains?(authority_name, "Venice") -> 8.5
      true -> 7.0
    end
  end

  defp get_or_create_award_list(authority, list_name, year) do
    case Repo.get_by(CuratedList, name: list_name, authority_id: authority.id) do
      nil ->
        {:ok, list} = Cultural.create_curated_list(%{
          name: list_name,
          authority_id: authority.id,
          list_type: "award",
          year: year,
          description: "Awards and nominations for #{year || "various years"}",
          prestige_score: 0.9
        })
        list
      existing ->
        existing
    end
  end

  defp build_award_notes(award) do
    parts = []
    parts = if award.category, do: ["Category: #{award.category}" | parts], else: parts
    parts = if award.year, do: ["Year: #{award.year}" | parts], else: parts
    parts = if award.award_id, do: ["Wikidata: #{award.award_id}" | parts], else: parts
    
    Enum.join(parts, "; ")
  end
end
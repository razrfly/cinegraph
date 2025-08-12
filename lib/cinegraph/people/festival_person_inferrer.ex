defmodule Cinegraph.People.FestivalPersonInferrer do
  @moduledoc """
  Infers person nominations for festivals based on movie credits and category type.
  
  Only reliable for director categories since there's typically one director per film.
  Actor categories cannot be reliably inferred since we don't know which actor was nominated.
  """
  
  import Ecto.Query
  alias Cinegraph.Repo
  alias Cinegraph.Movies.{Movie, Credit}
  alias Cinegraph.Festivals.{FestivalNomination, FestivalCategory}
  require Logger
  
  @director_category_patterns [
    "director",
    "directing",
    "réalisateur",
    "regia",
    "regie",
    "realizador"
  ]
  
  @doc """
  Infers and links person for director nominations only.
  Returns {:ok, updated_nomination} or {:error, reason}
  """
  def infer_director_nomination(%FestivalNomination{} = nomination) do
    with {:ok, category} <- get_category(nomination),
         true <- is_director_category?(category),
         {:ok, movie} <- get_movie(nomination),
         {:ok, director} <- find_director_for_movie(movie) do
      
      nomination
      |> Ecto.Changeset.change(%{person_id: director.person_id})
      |> Repo.update()
    else
      false ->
        {:skip, :not_director_category}
      {:error, reason} ->
        {:error, reason}
    end
  end
  
  @doc """
  Process all unlinked director nominations for non-Oscar festivals.
  """
  def infer_all_director_nominations do
    # Get all unlinked nominations from non-Oscar festivals
    unlinked = 
      from(n in FestivalNomination,
        join: cat in assoc(n, :category),
        join: cer in assoc(n, :ceremony),
        join: org in assoc(cer, :organization),
        where: is_nil(n.person_id),
        where: cat.tracks_person == true,
        where: org.abbreviation != "AMPAS",  # Skip Oscars - they have names
        preload: [:category]
      )
      |> Repo.all()
    
    results = Enum.map(unlinked, &infer_director_nomination/1)
    
    success_count = Enum.count(results, fn
      {:ok, _} -> true
      _ -> false
    end)
    
    skipped_count = Enum.count(results, fn
      {:skip, _} -> true
      _ -> false
    end)
    
    failed_count = Enum.count(results, fn
      {:error, _} -> true
      _ -> false
    end)
    
    Logger.info("Director inference complete: #{success_count} linked, #{skipped_count} skipped (not directors), #{failed_count} failed")
    
    %{
      success: success_count,
      skipped: skipped_count,
      failed: failed_count,
      total: length(unlinked)
    }
  end
  
  # Private functions
  
  defp get_category(%FestivalNomination{category: %FestivalCategory{} = cat}), do: {:ok, cat}
  defp get_category(%FestivalNomination{category_id: cat_id}) do
    case Repo.get(FestivalCategory, cat_id) do
      nil -> {:error, :category_not_found}
      cat -> {:ok, cat}
    end
  end
  
  defp is_director_category?(%FestivalCategory{name: name}) do
    normalized = String.downcase(name)
    
    Enum.any?(@director_category_patterns, fn pattern ->
      String.contains?(normalized, pattern)
    end)
  end
  
  defp get_movie(%FestivalNomination{movie_id: nil}), do: {:error, :no_movie}
  defp get_movie(%FestivalNomination{movie_id: movie_id}) do
    case Repo.get(Movie, movie_id) do
      nil -> {:error, :movie_not_found}
      movie -> {:ok, movie}
    end
  end
  
  defp find_director_for_movie(%Movie{id: movie_id}) do
    # Look for director in credits
    director_credit = 
      from(c in Credit,
        where: c.movie_id == ^movie_id,
        where: c.credit_type == "crew",
        where: c.department == "Directing",
        where: c.job == "Director",
        limit: 1
      )
      |> Repo.one()
    
    case director_credit do
      nil -> 
        # Try alternate job titles
        alternate_director = 
          from(c in Credit,
            where: c.movie_id == ^movie_id,
            where: c.credit_type == "crew",
            where: c.department == "Directing",
            where: fragment("LOWER(?) LIKE ?", c.job, "%director%"),
            limit: 1
          )
          |> Repo.one()
        
        case alternate_director do
          nil -> {:error, :director_not_found}
          credit -> {:ok, credit}
        end
        
      credit -> 
        {:ok, credit}
    end
  end
  
  @doc """
  Get statistics on what can be inferred.
  """
  def get_inference_stats do
    # Count director categories
    director_categories = 
      from(fc in FestivalCategory,
        join: org in assoc(fc, :organization),
        where: org.abbreviation != "AMPAS",
        where: fc.tracks_person == true,
        select: {fc.id, fc.name, org.name}
      )
      |> Repo.all()
      |> Enum.filter(fn {_id, name, _org} ->
        normalized = String.downcase(name)
        Enum.any?(@director_category_patterns, fn pattern ->
          String.contains?(normalized, pattern)
        end)
      end)
    
    # Count nominations in director categories
    director_category_ids = Enum.map(director_categories, fn {id, _, _} -> id end)
    
    director_noms_count = 
      from(n in FestivalNomination,
        where: n.category_id in ^director_category_ids,
        select: count(n.id)
      )
      |> Repo.one() || 0
    
    # Count already linked
    linked_count =
      from(n in FestivalNomination,
        where: n.category_id in ^director_category_ids,
        where: not is_nil(n.person_id),
        select: count(n.id)
      )
      |> Repo.one() || 0
    
    %{
      director_categories: Enum.map(director_categories, fn {_id, name, org} -> 
        "#{org}: #{name}"
      end),
      total_director_nominations: director_noms_count,
      already_linked: linked_count,
      can_be_inferred: director_noms_count - linked_count
    }
  end
end
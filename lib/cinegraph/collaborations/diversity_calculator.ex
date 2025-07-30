defmodule Cinegraph.Collaborations.DiversityCalculator do
  @moduledoc """
  Calculates diversity scores for collaborations.
  """
  
  import Ecto.Query
  alias Cinegraph.Repo
  alias Cinegraph.Collaborations.{Collaboration, CollaborationDetail}
  
  @doc """
  Updates diversity scores for all collaborations.
  Genre diversity: How many different genres they've worked in together.
  Role diversity: How many different collaboration types they have.
  """
  def update_all_diversity_scores do
    IO.puts("Calculating diversity scores for collaborations...")
    
    # Get all collaborations
    collaborations = Repo.all(Collaboration)
    total = length(collaborations)
    
    collaborations
    |> Enum.with_index(1)
    |> Enum.each(fn {collaboration, index} ->
      if rem(index, 1000) == 0 do
        IO.puts("Processing #{index}/#{total}...")
      end
      
      update_diversity_scores(collaboration)
    end)
    
    IO.puts("✓ Updated diversity scores for #{total} collaborations")
  end
  
  @doc """
  Updates diversity scores for a single collaboration.
  """
  def update_diversity_scores(%Collaboration{} = collaboration) do
    # Get all details for this collaboration
    details_query = from cd in CollaborationDetail,
      where: cd.collaboration_id == ^collaboration.id,
      select: {cd.collaboration_type, cd.movie_id}
    
    details = Repo.all(details_query)
    
    # Calculate role diversity (unique collaboration types)
    unique_roles = details
    |> Enum.map(fn {type, _} -> type end)
    |> Enum.uniq()
    |> length()
    
    # Normalize to 0-1 scale (assuming max 5 different role types)
    role_diversity = min(unique_roles / 5.0, 1.0)
    
    # Calculate genre diversity
    movie_ids = Enum.map(details, fn {_, movie_id} -> movie_id end) |> Enum.uniq()
    
    genre_count_query = from mg in "movie_genres",
      where: mg.movie_id in ^movie_ids,
      select: count(mg.genre_id, :distinct)
    
    unique_genres = Repo.one(genre_count_query) || 0
    
    # Normalize to 0-1 scale (assuming max 10 genres is very diverse)
    genre_diversity = min(unique_genres / 10.0, 1.0)
    
    # Update the collaboration
    collaboration
    |> Collaboration.changeset(%{
      genre_diversity_score: Decimal.from_float(genre_diversity),
      role_diversity_score: Decimal.from_float(role_diversity)
    })
    |> Repo.update!()
  end
  
  @doc """
  Shows diversity statistics.
  """
  def diversity_stats do
    query = from c in Collaboration,
      where: not is_nil(c.genre_diversity_score),
      select: %{
        total: count(c.id),
        avg_genre_diversity: avg(c.genre_diversity_score),
        avg_role_diversity: avg(c.role_diversity_score),
        high_genre_diversity: sum(fragment("CASE WHEN ? > 0.7 THEN 1 ELSE 0 END", c.genre_diversity_score)),
        high_role_diversity: sum(fragment("CASE WHEN ? > 0.7 THEN 1 ELSE 0 END", c.role_diversity_score))
      }
    
    Repo.one(query)
  end
end
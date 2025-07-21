defmodule Cinegraph.Cultural do
  @moduledoc """
  The Cultural context manages cultural authorities, curated lists, and 
  Cultural Relevance Index (CRI) calculations for movies.
  """

  import Ecto.Query, warn: false
  alias Cinegraph.Repo

  alias Cinegraph.Cultural.{
    Authority,
    CuratedList,
    MovieListItem,
    MovieDataChange,
    CRIScore
  }

  # ========================================
  # CULTURAL AUTHORITIES
  # ========================================

  @doc """
  Returns the list of cultural authorities.
  """
  def list_authorities do
    Repo.all(Authority)
  end

  @doc """
  Gets a single authority.
  """
  def get_authority!(id), do: Repo.get!(Authority, id)

  @doc """
  Gets an authority by name.
  """
  def get_authority_by_name(name) do
    Repo.get_by(Authority, name: name)
  end

  @doc """
  Creates an authority.
  """
  def create_authority(attrs \\ %{}) do
    %Authority{}
    |> Authority.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates an authority.
  """
  def update_authority(%Authority{} = authority, attrs) do
    authority
    |> Authority.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes an authority.
  """
  def delete_authority(%Authority{} = authority) do
    Repo.delete(authority)
  end

  # ========================================
  # CURATED LISTS
  # ========================================

  @doc """
  Returns the list of curated lists, optionally filtered by authority.
  """
  def list_curated_lists(authority_id \\ nil) do
    query = from l in CuratedList, preload: [:authority]
    
    query = 
      if authority_id do
        from l in query, where: l.authority_id == ^authority_id
      else
        query
      end
    
    Repo.all(query)
  end

  @doc """
  Gets a single curated list.
  """
  def get_curated_list!(id) do
    Repo.get!(CuratedList, id) |> Repo.preload([:authority, :movie_list_items])
  end

  @doc """
  Creates a curated list.
  """
  def create_curated_list(attrs \\ %{}) do
    %CuratedList{}
    |> CuratedList.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a curated list.
  """
  def update_curated_list(%CuratedList{} = list, attrs) do
    list
    |> CuratedList.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a curated list.
  """
  def delete_curated_list(%CuratedList{} = list) do
    Repo.delete(list)
  end

  # ========================================
  # MOVIE LIST ITEMS
  # ========================================

  @doc """
  Gets movies in a curated list.
  """
  def get_list_movies(list_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    
    from(item in MovieListItem,
      join: movie in assoc(item, :movie),
      where: item.list_id == ^list_id,
      order_by: [asc: item.rank, desc: item.inserted_at],
      limit: ^limit,
      preload: [movie: movie]
    )
    |> Repo.all()
  end

  @doc """
  Gets curated lists that contain a specific movie.
  """
  def get_list_movies_for_movie(movie_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    
    from(item in MovieListItem,
      join: list in assoc(item, :list),
      join: authority in assoc(list, :authority),
      where: item.movie_id == ^movie_id,
      order_by: [desc: list.prestige_score, asc: item.rank],
      limit: ^limit,
      preload: [list: {list, authority: authority}]
    )
    |> Repo.all()
  end

  @doc """
  Adds a movie to a curated list.
  """
  def add_movie_to_list(movie_id, list_id, attrs \\ %{}) do
    attrs = Map.merge(attrs, %{movie_id: movie_id, list_id: list_id})
    
    %MovieListItem{}
    |> MovieListItem.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Removes a movie from a curated list.
  """
  def remove_movie_from_list(movie_id, list_id, award_category \\ nil) do
    query = 
      from item in MovieListItem,
        where: item.movie_id == ^movie_id and item.list_id == ^list_id
    
    query = 
      if award_category do
        from item in query, where: item.award_category == ^award_category
      else
        query
      end
    
    Repo.delete_all(query)
  end

  # ========================================
  # CRI SCORING
  # ========================================

  @doc """
  Gets the latest CRI score for a movie.
  """
  def get_latest_cri_score(movie_id) do
    from(score in CRIScore,
      where: score.movie_id == ^movie_id,
      order_by: [desc: score.calculated_at],
      limit: 1
    )
    |> Repo.one()
  end

  @doc """
  Creates or updates a CRI score for a movie.
  """
  def upsert_cri_score(movie_id, score_value, components, version \\ "1.0") do
    attrs = %{
      movie_id: movie_id,
      score: score_value,
      components: components,
      version: version,
      calculated_at: DateTime.utc_now()
    }
    
    %CRIScore{}
    |> CRIScore.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Calculates Cultural Relevance Index for a movie.
  This is a simplified version - full implementation would be more complex.
  """
  def calculate_cri_score(movie_id) do
    # Get movie with all cultural data
    movie_cultural_data = get_movie_cultural_data(movie_id)
    
    components = %{
      "authority_presence" => calculate_authority_presence(movie_cultural_data),
      "list_appearances" => calculate_list_appearances(movie_cultural_data),
      "award_recognition" => calculate_award_recognition(movie_cultural_data),
      "cultural_impact" => calculate_cultural_impact(movie_cultural_data)
    }
    
    # Weighted average of components
    score = 
      (components["authority_presence"] * 0.3) +
      (components["list_appearances"] * 0.25) +
      (components["award_recognition"] * 0.35) +
      (components["cultural_impact"] * 0.1)
    
    # Scale to 0-100
    final_score = score * 100
    
    upsert_cri_score(movie_id, final_score, components)
  end

  # ========================================
  # MOVIE DATA CHANGES
  # ========================================

  @doc """
  Records a data change event for a movie.
  """
  def record_movie_change(movie_id, platform, change_type, attrs \\ %{}) do
    attrs = Map.merge(attrs, %{
      movie_id: movie_id,
      source_platform: platform,
      change_type: change_type
    })
    
    %MovieDataChange{}
    |> MovieDataChange.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Gets recent change activity for a movie.
  """
  def get_movie_change_activity(movie_id, days \\ 30) do
    since = DateTime.utc_now() |> DateTime.add(-days * 24 * 3600, :second)
    
    from(change in MovieDataChange,
      where: change.movie_id == ^movie_id and change.period_end >= ^since,
      order_by: [desc: change.period_end]
    )
    |> Repo.all()
  end

  # ========================================
  # SEED DATA FUNCTIONS
  # ========================================

  @doc """
  Seeds initial cultural authorities.
  """
  def seed_authorities do
    authorities = [
      %{
        name: "Academy of Motion Picture Arts and Sciences",
        authority_type: "award",
        category: "film_award",
        trust_score: 0.95,
        base_weight: 2.0,
        description: "The organization behind the Academy Awards (Oscars)",
        country_code: "US",
        established_year: 1927,
        data_source: "manual"
      },
      %{
        name: "Cannes Film Festival",
        authority_type: "award",
        category: "film_festival",
        trust_score: 0.90,
        base_weight: 1.8,
        description: "Prestigious international film festival",
        country_code: "FR",
        established_year: 1946,
        data_source: "manual"
      },
      %{
        name: "Criterion Collection",
        authority_type: "collection",
        category: "film_collection",
        trust_score: 0.88,
        base_weight: 1.5,
        description: "Curated collection of important classic and contemporary films",
        country_code: "US",
        established_year: 1984,
        data_source: "api"
      },
      %{
        name: "British Film Institute",
        authority_type: "critic",
        category: "cultural_institution",
        trust_score: 0.85,
        base_weight: 1.3,
        description: "UK's lead organisation for film, television and the moving image",
        country_code: "GB",
        established_year: 1933,
        data_source: "manual"
      }
    ]
    
    Enum.each(authorities, fn attrs ->
      case get_authority_by_name(attrs.name) do
        nil -> create_authority(attrs)
        _existing -> :ok
      end
    end)
  end

  # ========================================
  # PRIVATE HELPER FUNCTIONS
  # ========================================

  defp get_movie_cultural_data(movie_id) do
    from(movie in Cinegraph.Movies.Movie,
      left_join: list_items in assoc(movie, :movie_list_items),
      left_join: lists in assoc(list_items, :list),
      left_join: authorities in assoc(lists, :authority),
      where: movie.id == ^movie_id,
      preload: [movie_list_items: {list_items, list: {lists, authority: authorities}}]
    )
    |> Repo.one()
  end

  defp calculate_authority_presence(movie_data) do
    if movie_data && movie_data.movie_list_items do
      authorities = 
        movie_data.movie_list_items
        |> Enum.map(& &1.list.authority)
        |> Enum.uniq_by(& &1.id)
      
      # Weight by authority trust scores
      total_weight = 
        authorities
        |> Enum.map(& &1.trust_score * &1.base_weight)
        |> Enum.sum()
      
      # Normalize to 0-1 scale
      min(total_weight / 10.0, 1.0)
    else
      0.0
    end
  end

  defp calculate_list_appearances(movie_data) do
    if movie_data && movie_data.movie_list_items do
      count = length(movie_data.movie_list_items)
      # Logarithmic scale - more lists = higher score but with diminishing returns
      :math.log(count + 1) / :math.log(50)  # Max around 50 list appearances
    else
      0.0
    end
  end

  defp calculate_award_recognition(movie_data) do
    if movie_data && movie_data.movie_list_items do
      award_items = 
        movie_data.movie_list_items
        |> Enum.filter(& &1.award_result in ["winner", "nominee"])
      
      winners = Enum.count(award_items, & &1.award_result == "winner")
      nominees = Enum.count(award_items, & &1.award_result == "nominee")
      
      # Winners worth more than nominees
      score = (winners * 1.0) + (nominees * 0.5)
      
      # Normalize
      min(score / 10.0, 1.0)
    else
      0.0
    end
  end

  defp calculate_cultural_impact(movie_data) do
    if movie_data && movie_data.movie_list_items do
      # Average of prestige scores from lists
      prestige_scores = 
        movie_data.movie_list_items
        |> Enum.map(& &1.list.prestige_score)
        |> Enum.filter(& &1 != nil)
      
      if length(prestige_scores) > 0 do
        Enum.sum(prestige_scores) / length(prestige_scores)
      else
        0.0
      end
    else
      0.0
    end
  end
end
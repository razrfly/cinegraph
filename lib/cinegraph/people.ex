defmodule Cinegraph.People do
  @moduledoc """
  The People context for managing movie cast and crew members.
  """

  import Ecto.Query, warn: false
  alias Cinegraph.Repo
  alias Cinegraph.Movies.Person
  alias Cinegraph.Movies.Credit
  alias Cinegraph.Movies.Movie

  @doc """
  Returns the list of people with optional pagination.
  """
  def list_people(params \\ %{}) do
    Person
    |> order_by(desc: :popularity)
    |> paginate(params)
  end
  
  @doc """
  Returns the count of all people.
  """
  def count_people do
    Repo.aggregate(Person, :count, :id)
  end

  @doc """
  Gets a single person.
  Raises if the person does not exist.
  """
  def get_person!(id) do
    Repo.get!(Person, id)
  end
  
  @doc """
  Gets a single person.
  Returns nil if the person does not exist.
  """
  def get_person(id) do
    Repo.get(Person, id)
  end

  @doc """
  Gets a person with all their movies and credits preloaded.
  Raises if the person does not exist.
  """
  def get_person_with_credits!(id) do
    person = Repo.get!(Person, id)
    
    # Get all credits for this person with movie details
    credits = 
      Credit
      |> where([c], c.person_id == ^id)
      |> join(:inner, [c], m in Movie, on: c.movie_id == m.id)
      |> preload([c, m], movie: m)
      |> order_by([c, m], desc: m.release_date)
      |> Repo.all()
    
    # Separate cast and crew credits
    cast_credits = Enum.filter(credits, & &1.credit_type == "cast")
    crew_credits = Enum.filter(credits, & &1.credit_type == "crew")
    
    # Group crew credits by department
    crew_by_department = Enum.group_by(crew_credits, & &1.department)
    
    # Find frequent collaborators
    collaborators = find_frequent_collaborators(id, credits)
    
    person
    |> Map.put(:cast_credits, cast_credits)
    |> Map.put(:crew_credits, crew_credits)
    |> Map.put(:crew_by_department, crew_by_department)
    |> Map.put(:collaborators, collaborators)
    |> Map.put(:total_movies, length(Enum.uniq_by(credits, & &1.movie_id)))
  end
  
  @doc """
  Gets a person with all their movies and credits preloaded.
  Returns nil if the person does not exist.
  """
  def get_person_with_credits(id) do
    case Repo.get(Person, id) do
      nil -> nil
      person ->
        # Get all credits for this person with movie details
        credits = 
          Credit
          |> where([c], c.person_id == ^id)
          |> join(:inner, [c], m in Movie, on: c.movie_id == m.id)
          |> preload([c, m], movie: m)
          |> order_by([c, m], desc: m.release_date)
          |> Repo.all()
        
        # Separate cast and crew credits
        cast_credits = Enum.filter(credits, & &1.credit_type == "cast")
        crew_credits = Enum.filter(credits, & &1.credit_type == "crew")
        
        # Group crew credits by department
        crew_by_department = Enum.group_by(crew_credits, & &1.department)
        
        # Find frequent collaborators
        collaborators = find_frequent_collaborators(id, credits)
        
        person
        |> Map.put(:cast_credits, cast_credits)
        |> Map.put(:crew_credits, crew_credits)
        |> Map.put(:crew_by_department, crew_by_department)
        |> Map.put(:collaborators, collaborators)
        |> Map.put(:total_movies, length(Enum.uniq_by(credits, & &1.movie_id)))
    end
  end

  @doc """
  Finds people who frequently work with the given person.
  """
  def find_frequent_collaborators(person_id, credits \\ nil) do
    # If credits aren't provided, fetch them
    credits = credits || get_person_credits(person_id)
    
    movie_ids = Enum.map(credits, & &1.movie_id) |> Enum.uniq()
    
    # Find all other people who worked on the same movies
    collaborator_credits = 
      Credit
      |> where([c], c.movie_id in ^movie_ids and c.person_id != ^person_id)
      |> join(:inner, [c], p in Person, on: c.person_id == p.id)
      |> preload([c, p], person: p)
      |> Repo.all()
    
    # Group by person and count collaborations
    collaborator_credits
    |> Enum.group_by(& &1.person_id)
    |> Enum.map(fn {_person_id, person_credits} ->
      person = hd(person_credits).person
      movies_together = Enum.map(person_credits, & &1.movie_id) |> Enum.uniq() |> length()
      
      %{
        person: person,
        movies_together: movies_together,
        roles: Enum.map(person_credits, fn c ->
          if c.credit_type == "cast", do: "Actor", else: c.job
        end) |> Enum.uniq()
      }
    end)
    |> Enum.sort_by(& &1.movies_together, :desc)
    |> Enum.take(20)
  end

  @doc """
  Gets all credits for a person.
  """
  def get_person_credits(person_id) do
    Credit
    |> where([c], c.person_id == ^person_id)
    |> preload(:movie)
    |> Repo.all()
  end

  @doc """
  Searches for people by name.
  """
  def search_people(query) do
    search_term = "%#{query}%"
    
    Person
    |> where([p], ilike(p.name, ^search_term))
    |> order_by([p], desc: p.popularity)
    |> limit(20)
    |> Repo.all()
  end

  @doc """
  Gets career statistics for a person.
  """
  def get_career_stats(person_id) do
    credits = get_person_credits(person_id)
    
    movies = Enum.map(credits, & &1.movie) |> Enum.uniq_by(& &1.id)
    
    %{
      total_movies: length(movies),
      as_actor: Enum.count(credits, & &1.credit_type == "cast"),
      as_crew: Enum.count(credits, & &1.credit_type == "crew"),
      departments: credits 
        |> Enum.filter(& &1.credit_type == "crew")
        |> Enum.map(& &1.department)
        |> Enum.uniq()
        |> Enum.reject(&is_nil/1),
      years_active: calculate_years_active(movies),
      total_revenue: Enum.sum(Enum.map(movies, & (&1.revenue || 0))),
      average_rating: calculate_average_rating(movies)
    }
  end

  defp calculate_years_active(movies) do
    dates = 
      movies
      |> Enum.map(& &1.release_date)
      |> Enum.reject(&is_nil/1)
    
    if length(dates) > 0 do
      min_date = Enum.min(dates, Date)
      max_date = Enum.max(dates, Date)
      
      %{
        first_movie: min_date,
        latest_movie: max_date,
        years: max_date.year - min_date.year
      }
    else
      %{first_movie: nil, latest_movie: nil, years: 0}
    end
  end

  defp calculate_average_rating(movies) do
    ratings = 
      movies
      |> Enum.map(& &1.vote_average)
      |> Enum.reject(&is_nil/1)
    
    if length(ratings) > 0 do
      Float.round(Enum.sum(ratings) / length(ratings), 1)
    else
      nil
    end
  end

  defp paginate(query, %{"page" => page, "per_page" => per_page}) do
    with {page_num, _} <- Integer.parse(page || "1"),
         {per_page_num, _} <- Integer.parse(per_page || "50") do
      page_num = max(page_num, 1)
      per_page_num = per_page_num |> min(100) |> max(1)
      
      query
      |> limit(^per_page_num)
      |> offset(^((page_num - 1) * per_page_num))
      |> Repo.all()
    else
      _ -> paginate(query, %{})
    end
  end

  defp paginate(query, _params) do
    query
    |> limit(50)
    |> Repo.all()
  end
end
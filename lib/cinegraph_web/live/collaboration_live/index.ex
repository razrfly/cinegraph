defmodule CinegraphWeb.CollaborationLive.Index do
  use CinegraphWeb, :live_view

  alias Cinegraph.Collaborations
  alias Cinegraph.People

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Explore Collaborations")
      |> assign(:search_actor_id, nil)
      |> assign(:search_director_id, nil)
      |> assign(:search_results, nil)
      |> assign(:trending_collaborations, get_trending_collaborations())
      |> assign(:selected_collaboration, nil)
      |> assign(:similar_collaborations, nil)
      |> assign(:loading, false)
    
    {:ok, socket}
  end

  @impl true
  def handle_params(params, _url, socket) do
    # Handle person_id parameter if coming from person profile
    socket = 
      case params["person_id"] do
        nil -> socket
        person_id -> 
          person = People.get_person!(person_id)
          assign(socket, :highlighted_person, person)
      end
    
    {:noreply, socket}
  end

  @impl true
  def handle_event("search_collaborations", params, socket) do
    socket = assign(socket, :loading, true)
    
    actor_id = if params["actor_id"] != "", do: String.to_integer(params["actor_id"]), else: nil
    director_id = if params["director_id"] != "", do: String.to_integer(params["director_id"]), else: nil
    
    socket = 
      socket
      |> assign(:search_actor_id, actor_id)
      |> assign(:search_director_id, director_id)
    
    send(self(), {:search, actor_id, director_id})
    
    {:noreply, socket}
  end
  
  @impl true
  def handle_event("find_similar", %{"collaboration_id" => collab_id}, socket) do
    collaboration = get_collaboration_by_id(collab_id)
    
    if collaboration do
      similar = Collaborations.find_similar_collaborations(
        collaboration.person_a_id, 
        collaboration.person_b_id,
        limit: 10
      )
      
      socket
      |> assign(:selected_collaboration, collaboration)
      |> assign(:similar_collaborations, similar)
    else
      socket
    end
    
    {:noreply, socket}
  end
  
  @impl true
  def handle_info({:search, actor_id, director_id}, socket) do
    results = 
      cond do
        actor_id && director_id ->
          # Search for specific actor-director collaboration
          movies = Collaborations.find_actor_director_movies(actor_id, director_id)
          if length(movies) > 0 do
            [%{
              type: :actor_director,
              person_a: People.get_person!(actor_id),
              person_b: People.get_person!(director_id),
              movies: movies,
              collaboration_count: length(movies)
            }]
          else
            []
          end
          
        actor_id ->
          # Find all collaborations for an actor
          get_person_top_collaborations(actor_id)
          
        director_id ->
          # Find frequent actors for a director
          Collaborations.find_director_frequent_actors(director_id, limit: 20)
          |> Enum.map(fn result ->
            %{
              type: :director_actor,
              person_a: result.person,
              person_b: People.get_person!(director_id),
              collaboration_count: result.movie_count,
              avg_rating: result.avg_rating,
              total_revenue: result.total_revenue
            }
          end)
          
        true ->
          []
      end
    
    socket = 
      socket
      |> assign(:search_results, results)
      |> assign(:loading, false)
    
    {:noreply, socket}
  end
  
  # Private functions
  
  defp get_trending_collaborations do
    # Get collaborations from the last 2 years
    current_year = Date.utc_today().year
    start_year = current_year - 2
    
    Collaborations.find_trending_collaborations(start_year, limit: 12)
    |> Enum.map(fn collab ->
      # Get additional details
      details = get_collaboration_details(collab)
      Map.merge(collab, details)
    end)
  end
  
  defp get_collaboration_details(collaboration) do
    query = """
    SELECT 
      cd.collaboration_type,
      AVG(cd.movie_rating) as avg_rating,
      SUM(cd.movie_revenue) as total_revenue,
      COUNT(DISTINCT cd.movie_id) as movie_count,
      MAX(cd.year) as latest_year
    FROM collaboration_details cd
    WHERE cd.collaboration_id = $1
    GROUP BY cd.collaboration_type
    """
    
    case Cinegraph.Repo.query(query, [collaboration.id]) do
      {:ok, %{rows: [[type, avg_rating, revenue, count, year]]}} ->
        %{
          collaboration_type: type,
          avg_rating: avg_rating,
          total_revenue: revenue || 0,
          movie_count: count,
          latest_year: year
        }
      _ ->
        %{
          collaboration_type: "unknown",
          avg_rating: nil,
          total_revenue: 0,
          movie_count: 0,
          latest_year: nil
        }
    end
  end
  
  defp get_person_top_collaborations(person_id) do
    query = """
    SELECT 
      CASE 
        WHEN c.person_a_id = $1 THEN c.person_b_id 
        ELSE c.person_a_id 
      END as collaborator_id,
      c.collaboration_count,
      c.avg_movie_rating,
      c.total_revenue,
      c.latest_collaboration_date,
      STRING_AGG(DISTINCT cd.collaboration_type, ', ') as types
    FROM collaborations c
    JOIN collaboration_details cd ON cd.collaboration_id = c.id
    WHERE c.person_a_id = $1 OR c.person_b_id = $1
    GROUP BY c.id, c.person_a_id, c.person_b_id, c.collaboration_count,
             c.avg_movie_rating, c.total_revenue, c.latest_collaboration_date
    ORDER BY c.collaboration_count DESC, c.latest_collaboration_date DESC
    LIMIT 20
    """
    
    case Cinegraph.Repo.query(query, [person_id]) do
      {:ok, %{rows: rows}} ->
        person = People.get_person!(person_id)
        
        Enum.map(rows, fn [collab_id, count, rating, revenue, latest_date, types] ->
          collaborator = People.get_person!(collab_id)
          
          %{
            type: determine_primary_type(types),
            person_a: person,
            person_b: collaborator,
            collaboration_count: count,
            avg_rating: rating,
            total_revenue: revenue || 0,
            latest_date: latest_date,
            collaboration_types: String.split(types, ", ")
          }
        end)
      _ ->
        []
    end
  end
  
  defp determine_primary_type(types_string) do
    cond do
      String.contains?(types_string, "actor-director") -> :actor_director
      String.contains?(types_string, "actor-actor") -> :actor_actor
      String.contains?(types_string, "director-crew") -> :director_crew
      true -> :other
    end
  end
  
  defp get_collaboration_by_id(id) do
    Cinegraph.Repo.get(Collaborations.Collaboration, id)
    |> Cinegraph.Repo.preload([:person_a, :person_b])
  end
end
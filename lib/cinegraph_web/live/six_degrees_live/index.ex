defmodule CinegraphWeb.SixDegreesLive.Index do
  use CinegraphWeb, :live_view

  alias Cinegraph.People
  alias Cinegraph.Collaborations.PathFinder

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Six Degrees Game")
      |> assign(:player1_search, "")
      |> assign(:player1_results, [])
      |> assign(:player1_selected, nil)
      |> assign(:player2_search, "")
      |> assign(:player2_results, [])
      |> assign(:player2_selected, nil)
      |> assign(:searching_player1, false)
      |> assign(:searching_player2, false)
      |> assign(:finding_path, false)
      |> assign(:path_result, nil)
      |> assign(:game_stats, get_game_stats())
      |> assign(:recent_games, get_recent_games())
      |> assign(:show_leaderboard, false)
      |> assign(:leaderboard, [])
    
    {:ok, socket}
  end

  @impl true
  def handle_event("search_player1", %{"query" => query}, socket) do
    if String.length(query) >= 2 do
      send(self(), {:search_people, :player1, query})
      {:noreply, assign(socket, :searching_player1, true)}
    else
      {:noreply, assign(socket, :player1_results, [])}
    end
  end

  @impl true
  def handle_event("search_player2", %{"query" => query}, socket) do
    if String.length(query) >= 2 do
      send(self(), {:search_people, :player2, query})
      {:noreply, assign(socket, :searching_player2, true)}
    else
      {:noreply, assign(socket, :player2_results, [])}
    end
  end

  @impl true
  def handle_event("select_player1", %{"person_id" => person_id}, socket) do
    person = People.get_person!(person_id)
    socket =
      socket
      |> assign(:player1_selected, person)
      |> assign(:player1_search, person.name)
      |> assign(:player1_results, [])
      |> assign(:path_result, nil)
    
    {:noreply, socket}
  end

  @impl true
  def handle_event("select_player2", %{"person_id" => person_id}, socket) do
    person = People.get_person!(person_id)
    socket =
      socket
      |> assign(:player2_selected, person)
      |> assign(:player2_search, person.name)
      |> assign(:player2_results, [])
      |> assign(:path_result, nil)
    
    {:noreply, socket}
  end

  @impl true
  def handle_event("clear_player1", _params, socket) do
    socket =
      socket
      |> assign(:player1_selected, nil)
      |> assign(:player1_search, "")
      |> assign(:player1_results, [])
      |> assign(:path_result, nil)
    
    {:noreply, socket}
  end

  @impl true
  def handle_event("clear_player2", _params, socket) do
    socket =
      socket
      |> assign(:player2_selected, nil)
      |> assign(:player2_search, "")
      |> assign(:player2_results, [])
      |> assign(:path_result, nil)
    
    {:noreply, socket}
  end

  @impl true
  def handle_event("find_path", _params, socket) do
    if socket.assigns.player1_selected && socket.assigns.player2_selected do
      send(self(), :find_path)
      {:noreply, assign(socket, :finding_path, true)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("toggle_leaderboard", _params, socket) do
    socket =
      if socket.assigns.show_leaderboard do
        assign(socket, :show_leaderboard, false)
      else
        leaderboard = get_leaderboard()
        socket
        |> assign(:show_leaderboard, true)
        |> assign(:leaderboard, leaderboard)
      end
    
    {:noreply, socket}
  end

  @impl true
  def handle_info({:search_people, player, query}, socket) do
    results = People.search_people(query, limit: 10)
    
    socket =
      case player do
        :player1 ->
          socket
          |> assign(:player1_results, results)
          |> assign(:searching_player1, false)
        
        :player2 ->
          socket
          |> assign(:player2_results, results)
          |> assign(:searching_player2, false)
      end
    
    {:noreply, socket}
  end

  @impl true
  def handle_info(:find_path, socket) do
    start_time = System.monotonic_time(:millisecond)
    
    path_result = 
      case PathFinder.find_path_with_movies(
        socket.assigns.player1_selected.id,
        socket.assigns.player2_selected.id
      ) do
        {:ok, path} ->
          elapsed_time = System.monotonic_time(:millisecond) - start_time
          
          # Format path with movie details
          formatted_path = format_path(path)
          
          # Save game result
          save_game_result(
            socket.assigns.player1_selected,
            socket.assigns.player2_selected,
            length(path),
            elapsed_time
          )
          
          %{
            success: true,
            path: formatted_path,
            degrees: length(path),
            time_ms: elapsed_time
          }
        
        {:error, :no_path_found} ->
          elapsed_time = System.monotonic_time(:millisecond) - start_time
          
          %{
            success: false,
            message: "No connection found! These people are not connected within 6 degrees.",
            time_ms: elapsed_time
          }
      end
    
    socket =
      socket
      |> assign(:path_result, path_result)
      |> assign(:finding_path, false)
      |> assign(:game_stats, get_game_stats())
      |> assign(:recent_games, get_recent_games())
    
    {:noreply, socket}
  end

  # Private functions

  defp format_path(path) do
    Enum.map(path, fn {person_a_id, movie, person_b_id} ->
      person_a = People.get_person!(person_a_id)
      person_b = People.get_person!(person_b_id)
      
      %{
        person_a: person_a,
        person_b: person_b,
        movie: movie
      }
    end)
  end

  defp save_game_result(player1, player2, degrees, time_ms) do
    # In a real app, you'd save this to a database
    # For now, we'll just log it
    IO.puts("Game played: #{player1.name} → #{player2.name} (#{degrees} degrees, #{time_ms}ms)")
  end

  defp get_game_stats do
    # In a real app, these would come from the database
    %{
      total_games: 1337,
      avg_degrees: 3.2,
      success_rate: 94.5,
      avg_time_ms: 127
    }
  end

  defp get_recent_games do
    # In a real app, these would come from the database
    # For now, return sample data
    [
      %{
        player1: %{name: "Tom Hanks", id: 31},
        player2: %{name: "Kevin Bacon", id: 4724},
        degrees: 2,
        time_ago: "2 minutes ago"
      },
      %{
        player1: %{name: "Meryl Streep", id: 5064},
        player2: %{name: "Brad Pitt", id: 287},
        degrees: 3,
        time_ago: "5 minutes ago"
      },
      %{
        player1: %{name: "Leonardo DiCaprio", id: 6193},
        player2: %{name: "Morgan Freeman", id: 192},
        degrees: 2,
        time_ago: "8 minutes ago"
      }
    ]
  end

  defp get_leaderboard do
    # In a real app, this would come from the database
    # For now, return sample data
    [
      %{rank: 1, player1: "Scarlett Johansson", player2: "Gary Oldman", degrees: 1, players: "User123", date: "Today"},
      %{rank: 2, player1: "Tom Cruise", player2: "Helena Bonham Carter", degrees: 2, players: "MovieBuff", date: "Today"},
      %{rank: 3, player1: "Will Smith", player2: "Tilda Swinton", degrees: 2, players: "CinemaFan", date: "Yesterday"},
      %{rank: 4, player1: "Emma Stone", player2: "Ian McKellen", degrees: 3, players: "FilmGeek", date: "Yesterday"},
      %{rank: 5, player1: "Ryan Gosling", player2: "Maggie Smith", degrees: 3, players: "MovieLover", date: "2 days ago"}
    ]
  end
end
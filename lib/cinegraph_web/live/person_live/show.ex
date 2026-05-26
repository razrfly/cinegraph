defmodule CinegraphWeb.PersonLive.Show do
  use CinegraphWeb, :live_view

  alias Cinegraph.People
  alias Cinegraph.Collaborations
  alias Cinegraph.Festivals
  import CinegraphWeb.CollaborationComponents
  import CinegraphWeb.PersonHelpers, only: [person_slug_or_id: 1]
  import CinegraphWeb.SEOHelpers

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:active_tab, :acting)
     |> assign(:bio_expanded, false)}
  end

  @impl true
  # Handle TMDb ID lookup - redirect to canonical slug URL
  def handle_params(%{"tmdb_id" => tmdb_id}, _url, socket) do
    case People.get_person_by_tmdb_id(String.to_integer(tmdb_id)) do
      nil ->
        socket =
          socket
          |> put_flash(:error, "Person not found")
          |> push_navigate(to: ~p"/people")

        {:noreply, socket}

      person ->
        # Redirect to canonical slug URL if slug exists
        redirect_path = ~p"/people/#{person_slug_or_id(person)}"

        {:noreply, push_navigate(socket, to: redirect_path)}
    end
  end

  # Handle ID or slug lookup
  def handle_params(%{"id_or_slug" => id_or_slug}, _url, socket) do
    if is_numeric?(id_or_slug) do
      case Cinegraph.Repo.replica().get(Cinegraph.Movies.Person, String.to_integer(id_or_slug)) do
        nil ->
          {:noreply,
           socket |> put_flash(:error, "Person not found") |> push_navigate(to: ~p"/people")}

        %{slug: slug} when slug not in [nil, ""] ->
          {:noreply, push_navigate(socket, to: ~p"/people/#{slug}")}

        _ ->
          case People.get_person_with_credits_by_id_or_slug(id_or_slug) do
            nil ->
              {:noreply,
               socket |> put_flash(:error, "Person not found") |> push_navigate(to: ~p"/people")}

            person ->
              {:noreply, load_person_data(socket, person)}
          end
      end
    else
      case People.get_person_with_credits_by_id_or_slug(id_or_slug) do
        nil ->
          socket =
            socket
            |> put_flash(:error, "Person not found")
            |> push_navigate(to: ~p"/people")

          {:noreply, socket}

        person ->
          {:noreply, load_person_data(socket, person)}
      end
    end
  end

  defp is_numeric?(string) do
    case Integer.parse(string) do
      {_, ""} -> true
      _ -> false
    end
  end

  defp load_person_data(socket, person) do
    all_credits = (person.cast_credits || []) ++ (person.crew_credits || [])
    career_stats = People.get_career_stats(person.id, all_credits)
    collaboration_stats = get_collaboration_stats(person.id)
    frequent_collaborators = get_frequent_collaborators(person)
    award_stats = Festivals.get_person_nomination_stats(person.id)
    revenue_map = build_revenue_map(person)

    socket
    |> assign(:person, person)
    |> assign(:career_stats, career_stats)
    |> assign(:collaboration_stats, collaboration_stats)
    |> assign(:frequent_collaborators, frequent_collaborators)
    |> assign(:award_stats, award_stats)
    |> assign(:revenue_map, revenue_map)
    |> assign(:show_six_degrees, false)
    |> assign(:six_degrees_target, nil)
    |> assign(:six_degrees_path, nil)
    |> assign(:six_degrees_loading, false)
    |> assign_person_seo(person)
  end

  defp build_revenue_map(person) do
    cast = Map.get(person, :cast_credits, []) || []
    crew = Map.get(person, :crew_credits, []) || []

    (cast ++ crew)
    |> Enum.map(& &1.movie_id)
    |> People.revenue_map_for_movie_ids()
  end

  @impl true
  def handle_event("change_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, :active_tab, String.to_atom(tab))}
  end

  @impl true
  def handle_event("toggle_bio", _params, socket) do
    {:noreply, assign(socket, :bio_expanded, !socket.assigns.bio_expanded)}
  end

  @impl true
  def handle_event("toggle_six_degrees", _params, socket) do
    {:noreply, assign(socket, :show_six_degrees, !socket.assigns.show_six_degrees)}
  end

  @impl true
  def handle_event("search_six_degrees", %{"target_person_id" => target_id}, socket)
      when target_id != "" do
    case Integer.parse(target_id) do
      {int_id, ""} ->
        socket = assign(socket, :six_degrees_loading, true)
        send(self(), {:find_path, int_id})
        {:noreply, socket}

      _ ->
        {:noreply, put_flash(socket, :error, "Invalid target person ID")}
    end
  end

  def handle_event("search_six_degrees", _params, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_info({:find_path, target_id}, socket) do
    from_id = socket.assigns.person.id

    case Collaborations.PathFinder.find_path_with_movies(from_id, target_id) do
      {:ok, path} ->
        {:noreply,
         socket
         |> assign(:six_degrees_path, path)
         |> assign(:six_degrees_loading, false)}

      {:error, :no_path_found} ->
        {:noreply,
         socket
         |> assign(:six_degrees_path, :no_path)
         |> assign(:six_degrees_loading, false)}
    end
  end

  # Private functions

  defp get_collaboration_stats(person_id) do
    person_id_int = if is_binary(person_id), do: String.to_integer(person_id), else: person_id

    # Get unique collaborators count
    query = """
    SELECT COUNT(DISTINCT CASE 
      WHEN person_a_id = $1 THEN person_b_id 
      ELSE person_a_id 
    END) as total_collaborators,
    COUNT(DISTINCT CASE 
      WHEN cd.collaboration_type = 'actor-director' AND c.person_a_id = $1 THEN c.person_b_id
      WHEN cd.collaboration_type = 'actor-director' AND c.person_b_id = $1 THEN c.person_a_id
    END) as unique_directors,
    COUNT(DISTINCT CASE 
      WHEN c.collaboration_count >= 3 AND c.person_a_id = $1 THEN c.person_b_id
      WHEN c.collaboration_count >= 3 AND c.person_b_id = $1 THEN c.person_a_id
    END) as recurring_partners
    FROM collaborations c
    LEFT JOIN collaboration_details cd ON cd.collaboration_id = c.id
    WHERE c.person_a_id = $1 OR c.person_b_id = $1
    """

    case Cinegraph.Repo.replica().query(query, [person_id_int]) do
      {:ok, %{rows: [[total, directors, recurring]]}} ->
        # Get peak collaboration year
        trends = Collaborations.get_person_collaboration_trends(person_id_int)

        peak_year =
          if length(trends) > 0 do
            Enum.max_by(trends, & &1.unique_collaborators)[:year]
          else
            nil
          end

        %{
          total_collaborators: total || 0,
          unique_directors: directors || 0,
          recurring_partners: recurring || 0,
          peak_year: peak_year
        }

      _ ->
        %{
          total_collaborators: 0,
          unique_directors: 0,
          recurring_partners: 0,
          peak_year: nil
        }
    end
  end

  defp get_frequent_collaborators(person) do
    person_id = if is_binary(person.id), do: String.to_integer(person.id), else: person.id

    query = """
    SELECT
      CASE WHEN c.person_a_id = $1 THEN c.person_b_id ELSE c.person_a_id END as collaborator_id,
      c.collaboration_count,
      c.first_collaboration_date,
      c.latest_collaboration_date,
      c.avg_movie_rating,
      c.total_revenue,
      STRING_AGG(DISTINCT cd.collaboration_type, ', ') as collaboration_types,
      p.id, p.name, p.slug, p.profile_path, p.known_for_department
    FROM collaborations c
    JOIN collaboration_details cd ON cd.collaboration_id = c.id
    JOIN people p ON p.id = (CASE WHEN c.person_a_id = $1 THEN c.person_b_id ELSE c.person_a_id END)
    WHERE (c.person_a_id = $1 OR c.person_b_id = $1)
      AND c.collaboration_count >= 2
    GROUP BY c.id, c.person_a_id, c.person_b_id, c.collaboration_count,
             c.first_collaboration_date, c.latest_collaboration_date,
             c.avg_movie_rating, c.total_revenue,
             p.id, p.name, p.slug, p.profile_path, p.known_for_department
    ORDER BY c.collaboration_count DESC, c.latest_collaboration_date DESC
    LIMIT 12
    """

    alias Cinegraph.Movies.Person

    case Cinegraph.Repo.replica().query(query, [person_id]) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [
                            _collab_id,
                            count,
                            first_date,
                            last_date,
                            avg_rating,
                            revenue,
                            types,
                            pid,
                            name,
                            slug,
                            profile_path,
                            department
                          ] ->
          %{
            person: %Person{
              id: pid,
              name: name,
              slug: slug,
              profile_path: profile_path,
              known_for_department: department
            },
            collaboration_count: count,
            first_date: first_date,
            latest_date: last_date,
            avg_rating: avg_rating,
            total_revenue: revenue,
            collaboration_types: String.split(types || "", ", "),
            strength:
              cond do
                count >= 10 -> :very_strong
                count >= 5 -> :strong
                true -> :moderate
              end
          }
        end)

      _ ->
        []
    end
  end
end

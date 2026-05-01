defmodule CinegraphWeb.PersonLive.Movies do
  @moduledoc """
  V2 movie discovery page scoped to one person.
  """
  use CinegraphWeb, :live_view
  use CinegraphWeb.SearchEventHandlers

  alias Cinegraph.Movies.Person
  alias Cinegraph.Movies.Search
  alias Cinegraph.People
  alias CinegraphWeb.MovieLive.IndexV2.Events
  alias CinegraphWeb.MovieLive.IndexV2.Results
  alias CinegraphWeb.MovieLive.SortOptions

  import CinegraphWeb.PersonHelpers, only: [person_slug_or_id: 1]

  import CinegraphWeb.LiveViewHelpers,
    only: [
      extract_sort_criteria: 1,
      extract_sort_direction: 1,
      assign_pagination: 2
    ]

  @impl CinegraphWeb.SearchEventHandlers
  def build_path(socket, params) do
    person = socket.assigns.person

    case socket.assigns.role_scope do
      :acting -> ~p"/people/#{person_slug_or_id(person)}/movies/acting?#{params}"
      :directing -> ~p"/people/#{person_slug_or_id(person)}/movies/directing?#{params}"
      _ -> ~p"/people/#{person_slug_or_id(person)}/movies?#{params}"
    end
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:movies, [])
     |> assign(:meta, %{})
     |> assign(:person, nil)
     |> assign(:params, %{})
     |> assign(:search_term, "")
     |> assign(:active_nav, "People")
     |> assign(:filter_options, Search.get_filter_options())
     |> assign(:sort_options, SortOptions.all())
     |> assign(:sort_criteria, "release_date")
     |> assign(:sort_direction, :desc)
     |> assign(:sort_is_preset, false)
     |> assign(:active_lens_key, nil)
     |> assign(:role_scope, :all)
     |> assign(:show_drawer, false)
     |> assign(:show_scoring_info, false)
     |> assign(:show_filters, false)
     |> assign(:person_options, [])}
  end

  @impl true
  def handle_params(%{"slug_or_id" => slug_or_id} = params, _url, socket) do
    case People.get_person_by_id_or_slug(slug_or_id) do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, "Person not found")
         |> push_navigate(to: ~p"/people")}

      person ->
        load_person_movies(person, params, socket)
    end
  end

  defp load_person_movies(person, params, socket) do
    page_params = Map.delete(params, "slug_or_id")
    role_scope = determine_role_scope(socket.assigns.live_action)
    sort_param = params["sort"] || "release_date_desc"
    criteria = extract_sort_criteria(sort_param)
    direction = extract_sort_direction(sort_param)
    sort_is_preset = SortOptions.preset?(criteria)
    active_lens_key = SortOptions.active_lens_key(criteria)

    search_params =
      params
      |> Map.put("people_ids", to_string(person.id))
      |> Map.put("per_page", "24")
      |> maybe_put_role(role_scope)
      |> Map.delete("slug_or_id")

    case Search.search_movies(search_params) do
      {:ok, {movies, meta}} ->
        movies = Results.preload_card_assocs(movies, active_lens_key)

        {:noreply,
         socket
         |> assign(:person, person)
         |> assign(:movies, movies)
         |> assign(:meta, meta)
         |> assign(:params, page_params)
         |> assign(:role_scope, role_scope)
         |> assign(:search_term, params["search"] || "")
         |> assign(:sort_criteria, criteria)
         |> assign(:sort_direction, direction)
         |> assign(:sort_is_preset, sort_is_preset)
         |> assign(:active_lens_key, active_lens_key)
         |> assign(:page_title, page_title(person, role_scope))
         |> assign_pagination(meta)}

      {:error, _changeset} ->
        meta = empty_pagination_meta()

        {:noreply,
         socket
         |> assign(:person, person)
         |> assign(:movies, [])
         |> assign(:meta, meta)
         |> assign(:params, page_params)
         |> assign(:role_scope, role_scope)
         |> assign(:search_term, params["search"] || "")
         |> assign(:sort_criteria, criteria)
         |> assign(:sort_direction, direction)
         |> assign(:sort_is_preset, sort_is_preset)
         |> assign(:active_lens_key, active_lens_key)
         |> assign(:page_title, page_title(person, role_scope))
         |> assign_pagination(meta)
         |> put_flash(:error, "Unable to load movies")}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("change_role", %{"role" => role}, socket) do
    person = socket.assigns.person

    path =
      case role do
        "acting" -> ~p"/people/#{person_slug_or_id(person)}/movies/acting"
        "directing" -> ~p"/people/#{person_slug_or_id(person)}/movies/directing"
        _ -> ~p"/people/#{person_slug_or_id(person)}/movies"
      end

    {:noreply, push_navigate(socket, to: path)}
  end

  @impl Phoenix.LiveView
  def handle_event(event, params, socket) do
    case Events.handle_event(event, params, socket) do
      :unknown -> super(event, params, socket)
      reply -> reply
    end
  end

  defp determine_role_scope(:acting), do: :acting
  defp determine_role_scope(:directing), do: :directing
  defp determine_role_scope(_), do: :all

  defp maybe_put_role(params, :acting), do: Map.put(params, "people_role", "cast")
  defp maybe_put_role(params, :directing), do: Map.put(params, "people_role", "director")
  defp maybe_put_role(params, _), do: params

  defp page_title(person, :acting), do: "#{person.name} - Acting Credits"
  defp page_title(person, :directing), do: "#{person.name} - Directed Films"
  defp page_title(person, _), do: "#{person.name} - Movies"

  defp empty_pagination_meta do
    %{
      total_count: 0,
      total_pages: 1,
      current_page: 1,
      page_size: 24
    }
  end

  def profile_url(%Person{profile_path: nil}), do: nil
  def profile_url(%Person{profile_path: path}), do: "https://image.tmdb.org/t/p/w342#{path}"
end

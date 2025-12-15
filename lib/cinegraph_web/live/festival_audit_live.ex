defmodule CinegraphWeb.FestivalAuditLive do
  @moduledoc """
  LiveView for auditing festival nominations.
  Allows administrators to review nominations by festival/year and
  either delete incorrect nominations or switch them to the correct movie.

  See GitHub Issue #479 for full design documentation.
  """
  use CinegraphWeb, :live_view

  alias Cinegraph.Festivals
  alias Cinegraph.Movies

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Festival Nomination Audit")
     |> assign(:organizations, [])
     |> assign(:selected_org, nil)
     |> assign(:ceremonies, [])
     |> assign(:filtered_ceremonies, [])
     |> assign(:selected_ceremony, nil)
     |> assign(:nominations_by_category, %{})
     |> assign(:show_switch_modal, false)
     |> assign(:show_delete_modal, false)
     |> assign(:selected_nomination, nil)
     |> assign(:movie_candidates, [])
     |> assign(:search_query, "")
     # Filters for year list
     |> assign(:year_filter, "all")
     |> assign(:status_filter, "all")
     # Filters for nomination view
     |> assign(:category_filter, "all")
     |> assign(:categories, [])
     |> assign(:collapsed_categories, MapSet.new())
     |> assign(:show_flagged_only, false)}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    organizations = Festivals.list_organizations()

    # Enrich organizations with stats
    organizations_with_stats =
      Enum.map(organizations, fn org ->
        ceremony_count = get_ceremony_count(org.id)
        nomination_count = Festivals.count_movies_for_organization(org.id)
        most_recent_year = get_most_recent_year(org.id)

        %{
          organization: org,
          ceremony_count: ceremony_count,
          nomination_count: nomination_count,
          most_recent_year: most_recent_year
        }
      end)

    socket
    |> assign(:page_title, "Festival Nomination Audit")
    |> assign(:organizations, organizations_with_stats)
    |> assign(:selected_org, nil)
    |> assign(:ceremonies, [])
    |> assign(:selected_ceremony, nil)
  end

  defp apply_action(socket, :organization, %{"org_slug" => org_slug}) do
    case Festivals.get_organization_by_slug(org_slug) do
      nil ->
        socket
        |> put_flash(:error, "Organization not found")
        |> push_navigate(to: ~p"/admin/festival")

      org ->
        ceremonies = load_ceremonies_with_stats(org.id)

        socket
        |> assign(:page_title, "#{org.name} - Festival Audit")
        |> assign(:selected_org, org)
        |> assign(:ceremonies, ceremonies)
        |> assign(:filtered_ceremonies, ceremonies)
        |> assign(:selected_ceremony, nil)
        |> assign(:year_filter, "all")
        |> assign(:status_filter, "all")
    end
  end

  defp apply_action(socket, :ceremony, %{"org_slug" => org_slug, "year" => year_str}) do
    with org when not is_nil(org) <- Festivals.get_organization_by_slug(org_slug),
         {year, ""} <- Integer.parse(year_str),
         ceremony when not is_nil(ceremony) <- Festivals.get_ceremony_by_year(org.id, year) do
      nominations_by_category = Festivals.get_ceremony_nominations_for_audit(ceremony.id)
      categories = Festivals.get_ceremony_categories(ceremony.id)

      socket
      |> assign(:page_title, "#{org.name} #{year} - Festival Audit")
      |> assign(:selected_org, org)
      |> assign(:selected_ceremony, ceremony)
      |> assign(:nominations_by_category, nominations_by_category)
      |> assign(:categories, categories)
      |> assign(:category_filter, "all")
      |> assign(:collapsed_categories, MapSet.new())
      |> assign(:show_flagged_only, false)
    else
      _ ->
        socket
        |> put_flash(:error, "Ceremony not found")
        |> push_navigate(to: ~p"/admin/festival")
    end
  end

  # Event handlers for filters

  @impl true
  def handle_event("filter_year", %{"year" => year_filter}, socket) do
    filtered = apply_filters(socket.assigns.ceremonies, year_filter, socket.assigns.status_filter)

    {:noreply,
     socket
     |> assign(:year_filter, year_filter)
     |> assign(:filtered_ceremonies, filtered)}
  end

  @impl true
  def handle_event("filter_status", %{"status" => status_filter}, socket) do
    filtered = apply_filters(socket.assigns.ceremonies, socket.assigns.year_filter, status_filter)

    {:noreply,
     socket
     |> assign(:status_filter, status_filter)
     |> assign(:filtered_ceremonies, filtered)}
  end

  @impl true
  def handle_event("filter_category", %{"category" => category_filter}, socket) do
    {:noreply, assign(socket, :category_filter, category_filter)}
  end

  @impl true
  def handle_event("toggle_category", %{"category" => category_name}, socket) do
    collapsed = socket.assigns.collapsed_categories

    new_collapsed =
      if MapSet.member?(collapsed, category_name) do
        MapSet.delete(collapsed, category_name)
      else
        MapSet.put(collapsed, category_name)
      end

    {:noreply, assign(socket, :collapsed_categories, new_collapsed)}
  end

  @impl true
  def handle_event("expand_all", _params, socket) do
    {:noreply, assign(socket, :collapsed_categories, MapSet.new())}
  end

  @impl true
  def handle_event("collapse_all", _params, socket) do
    all_categories = MapSet.new(socket.assigns.categories)
    {:noreply, assign(socket, :collapsed_categories, all_categories)}
  end

  @impl true
  def handle_event("toggle_flagged_only", _params, socket) do
    {:noreply, assign(socket, :show_flagged_only, !socket.assigns.show_flagged_only)}
  end

  # Delete modal events
  @impl true
  def handle_event("show_delete_modal", %{"nomination-id" => nomination_id}, socket) do
    nomination_id = String.to_integer(nomination_id)

    case Festivals.get_nomination(nomination_id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Nomination no longer exists.")}

      nomination ->
        {:noreply,
         socket
         |> assign(:show_delete_modal, true)
         |> assign(:selected_nomination, nomination)}
    end
  end

  @impl true
  def handle_event("close_delete_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_delete_modal, false)
     |> assign(:selected_nomination, nil)}
  end

  @impl true
  def handle_event("confirm_delete", _params, socket) do
    nomination = socket.assigns.selected_nomination

    case Festivals.delete_nomination(nomination.id) do
      {:ok, _deleted} ->
        # Reload nominations for the ceremony
        nominations_by_category =
          Festivals.get_ceremony_nominations_for_audit(socket.assigns.selected_ceremony.id)

        categories = Festivals.get_ceremony_categories(socket.assigns.selected_ceremony.id)

        {:noreply,
         socket
         |> assign(:show_delete_modal, false)
         |> assign(:selected_nomination, nil)
         |> assign(:nominations_by_category, nominations_by_category)
         |> assign(:categories, categories)
         |> put_flash(:info, "Nomination for \"#{nomination.movie.title}\" deleted successfully.")}

      {:error, :not_found} ->
        {:noreply,
         socket
         |> assign(:show_delete_modal, false)
         |> assign(:selected_nomination, nil)
         |> put_flash(:error, "Nomination not found. It may have already been deleted.")}

      {:error, _reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "Failed to delete nomination. Please try again.")}
    end
  end

  # Switch modal events
  @impl true
  def handle_event("show_switch_modal", %{"nomination-id" => nomination_id}, socket) do
    nomination_id = String.to_integer(nomination_id)

    case Festivals.get_nomination(nomination_id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Nomination no longer exists.")}

      %{movie: nil} ->
        {:noreply, put_flash(socket, :error, "Nomination has no linked movie to switch.")}

      %{movie: %{title: nil}} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Nomination's movie has no title, so candidates can't be searched."
         )}

      nomination ->
        title = nomination.movie.title

        # Pre-populate with candidates based on current movie title
        candidates =
          Festivals.find_candidate_movies(
            title,
            socket.assigns.selected_ceremony.year,
            limit: 10
          )

        {:noreply,
         socket
         |> assign(:show_switch_modal, true)
         |> assign(:selected_nomination, nomination)
         |> assign(:movie_candidates, candidates)
         |> assign(:search_query, title)}
    end
  end

  @impl true
  def handle_event("close_switch_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_switch_modal, false)
     |> assign(:selected_nomination, nil)
     |> assign(:movie_candidates, [])
     |> assign(:search_query, "")}
  end

  @impl true
  def handle_event("search_movies", %{"value" => query}, socket) do
    candidates =
      if String.length(String.trim(query)) >= 2 do
        Movies.quick_search(query, limit: 15)
      else
        []
      end

    {:noreply,
     socket
     |> assign(:search_query, query)
     |> assign(:movie_candidates, candidates)}
  end

  @impl true
  def handle_event("confirm_switch", %{"movie-id" => movie_id}, socket) do
    nomination = socket.assigns.selected_nomination
    movie_id = String.to_integer(movie_id)

    case Festivals.switch_nomination_movie(nomination.id, movie_id) do
      {:ok, updated_nomination} ->
        # Reload nominations for the ceremony
        nominations_by_category =
          Festivals.get_ceremony_nominations_for_audit(socket.assigns.selected_ceremony.id)

        categories = Festivals.get_ceremony_categories(socket.assigns.selected_ceremony.id)

        {:noreply,
         socket
         |> assign(:show_switch_modal, false)
         |> assign(:selected_nomination, nil)
         |> assign(:movie_candidates, [])
         |> assign(:search_query, "")
         |> assign(:nominations_by_category, nominations_by_category)
         |> assign(:categories, categories)
         |> put_flash(
           :info,
           "Switched nomination from \"#{nomination.movie.title}\" to \"#{updated_nomination.movie.title}\"."
         )}

      {:error, :not_found} ->
        {:noreply,
         socket
         |> assign(:show_switch_modal, false)
         |> assign(:selected_nomination, nil)
         |> put_flash(:error, "Nomination not found. It may have been deleted.")}

      {:error, _reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "Failed to switch movie. Please try again.")}
    end
  end

  defp apply_filters(ceremonies, year_filter, status_filter) do
    ceremonies
    |> filter_by_year(year_filter)
    |> filter_by_status(status_filter)
  end

  defp filter_by_year(ceremonies, "all"), do: ceremonies

  defp filter_by_year(ceremonies, "recent") do
    current_year = Date.utc_today().year
    Enum.filter(ceremonies, fn c -> c.ceremony.year >= current_year - 5 end)
  end

  defp filter_by_year(ceremonies, "2020s") do
    Enum.filter(ceremonies, fn c -> c.ceremony.year >= 2020 and c.ceremony.year < 2030 end)
  end

  defp filter_by_year(ceremonies, "2010s") do
    Enum.filter(ceremonies, fn c -> c.ceremony.year >= 2010 and c.ceremony.year < 2020 end)
  end

  defp filter_by_year(ceremonies, "2000s") do
    Enum.filter(ceremonies, fn c -> c.ceremony.year >= 2000 and c.ceremony.year < 2010 end)
  end

  defp filter_by_year(ceremonies, "older") do
    Enum.filter(ceremonies, fn c -> c.ceremony.year < 2000 end)
  end

  defp filter_by_year(ceremonies, _), do: ceremonies

  defp filter_by_status(ceremonies, "all"), do: ceremonies

  defp filter_by_status(ceremonies, "with_nominations") do
    Enum.filter(ceremonies, fn c -> c.nomination_count > 0 end)
  end

  defp filter_by_status(ceremonies, "empty") do
    Enum.filter(ceremonies, fn c -> c.nomination_count == 0 end)
  end

  defp filter_by_status(ceremonies, _), do: ceremonies

  # Category filtering for ceremony view
  defp filter_categories(nominations_by_category, "all"), do: nominations_by_category

  defp filter_categories(nominations_by_category, category_name) do
    case Map.get(nominations_by_category, category_name) do
      nil -> %{}
      nominations -> %{category_name => nominations}
    end
  end

  # Flagging logic for nominations
  # Returns a list of flags: [{:error, message} | {:warning, message}]
  @doc false
  def flag_nomination(nomination, ceremony) do
    flags = []

    movie = nomination.movie
    eligible_year = ceremony.year - 1
    movie_year = if movie.release_date, do: movie.release_date.year, else: nil

    # Flag 1: Movie released AFTER eligibility period (error)
    flags =
      if movie_year && movie_year > ceremony.year do
        [{:error, "Release date (#{movie_year}) after ceremony year"} | flags]
      else
        flags
      end

    # Flag 2: Movie released too early (>3 years before eligibility) (warning)
    flags =
      if movie_year && movie_year < eligible_year - 2 do
        years_diff = eligible_year - movie_year

        [
          {:warning, "Release date (#{movie_year}) is #{years_diff} years before eligibility"}
          | flags
        ]
      else
        flags
      end

    # Flag 3: Missing external IDs (warning)
    flags =
      if is_nil(movie.tmdb_id) && is_nil(movie.imdb_id) do
        [{:warning, "Missing external IDs (TMDb/IMDb)"} | flags]
      else
        flags
      end

    flags
  end

  @doc false
  def has_flags?(nomination, ceremony) do
    flag_nomination(nomination, ceremony) != []
  end

  @doc false
  def has_errors?(nomination, ceremony) do
    nomination
    |> flag_nomination(ceremony)
    |> Enum.any?(fn {type, _} -> type == :error end)
  end

  @doc false
  def has_warnings?(nomination, ceremony) do
    nomination
    |> flag_nomination(ceremony)
    |> Enum.any?(fn {type, _} -> type == :warning end)
  end

  # Filter nominations to only show flagged ones when show_flagged_only is true
  defp filter_flagged(nominations_by_category, false, _ceremony), do: nominations_by_category

  defp filter_flagged(nominations_by_category, true, ceremony) do
    nominations_by_category
    |> Enum.map(fn {category, nominations} ->
      flagged = Enum.filter(nominations, fn nom -> has_flags?(nom, ceremony) end)
      {category, flagged}
    end)
    |> Enum.reject(fn {_category, nominations} -> Enum.empty?(nominations) end)
    |> Enum.into(%{})
  end

  # Count total flagged nominations
  defp count_flagged(nominations_by_category, ceremony) do
    nominations_by_category
    |> Enum.flat_map(fn {_category, nominations} -> nominations end)
    |> Enum.count(fn nom -> has_flags?(nom, ceremony) end)
  end

  # Helper functions

  defp get_ceremony_count(organization_id) do
    organization_id
    |> Festivals.list_ceremonies()
    |> length()
  end

  defp get_most_recent_year(organization_id) do
    case Festivals.list_ceremonies(organization_id) do
      [ceremony | _] -> ceremony.year
      [] -> nil
    end
  end

  defp load_ceremonies_with_stats(organization_id) do
    organization_id
    |> Festivals.list_ceremonies()
    |> Enum.map(fn ceremony ->
      nomination_count = Festivals.count_nominations(ceremony.id)
      win_count = Festivals.count_wins(ceremony.id)

      %{
        ceremony: ceremony,
        nomination_count: nomination_count,
        win_count: win_count
      }
    end)
  end
end

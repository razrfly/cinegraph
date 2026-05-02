defmodule CinegraphWeb.CompanyLive.Show do
  @moduledoc """
  Movie discovery page scoped to one production company.
  """
  use CinegraphWeb, :live_view
  use CinegraphWeb.SearchEventHandlers

  alias Cinegraph.Movies
  alias Cinegraph.Movies.ProductionCompany
  alias Cinegraph.Movies.Search
  alias CinegraphWeb.MovieLive.IndexV2.Events
  alias CinegraphWeb.MovieLive.IndexV2.Results
  alias CinegraphWeb.MovieLive.SortOptions

  import CinegraphWeb.LiveViewHelpers,
    only: [
      extract_sort_criteria: 1,
      extract_sort_direction: 1,
      assign_pagination: 2
    ]

  @site_url "https://cinegraph.io"

  @impl CinegraphWeb.SearchEventHandlers
  def build_path(socket, params) do
    company = socket.assigns.company
    ~p"/companies/#{company.slug || company.id}?#{params}"
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:movies, [])
     |> assign(:meta, %{})
     |> assign(:company, nil)
     |> assign(:params, %{})
     |> assign(:search_term, "")
     |> assign(:active_nav, "Companies")
     |> assign(:filter_options, Search.get_filter_options())
     |> assign(:sort_options, SortOptions.all())
     |> assign(:sort_criteria, "release_date")
     |> assign(:sort_direction, :desc)
     |> assign(:sort_is_preset, false)
     |> assign(:active_lens_key, nil)
     |> assign(:show_drawer, false)
     |> assign(:show_scoring_info, false)
     |> assign(:show_filters, false)
     |> assign(:person_options, [])}
  end

  @impl true
  def handle_params(%{"slug_or_id" => slug_or_id} = params, _url, socket) do
    case Movies.get_production_company_by_id_or_slug(slug_or_id) do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, "Company not found")
         |> push_navigate(to: ~p"/companies")}

      company ->
        load_company_page(company, params, socket)
    end
  end

  defp load_company_page(company, params, socket) do
    page_params = Map.delete(params, "slug_or_id")
    sort_param = params["sort"] || "release_date_desc"
    criteria = extract_sort_criteria(sort_param)
    direction = extract_sort_direction(sort_param)
    sort_is_preset = SortOptions.preset?(criteria)
    active_lens_key = SortOptions.active_lens_key(criteria)

    search_params =
      params
      |> Map.put("companies", to_string(company.id))
      |> Map.put("per_page", "24")
      |> Map.delete("slug_or_id")

    case Search.search_movies(search_params) do
      {:ok, {movies, meta}} ->
        movies = Results.preload_card_assocs(movies, active_lens_key)

        {:noreply,
         socket
         |> assign(:company, company)
         |> assign(:movies, movies)
         |> assign(:meta, meta)
         |> assign(:params, page_params)
         |> assign(:search_term, params["search"] || "")
         |> assign(:sort_criteria, criteria)
         |> assign(:sort_direction, direction)
         |> assign(:sort_is_preset, sort_is_preset)
         |> assign(:active_lens_key, active_lens_key)
         |> assign_pagination(meta)
         |> assign_company_page_seo(company, movies)}

      {:error, _changeset} ->
        meta = empty_pagination_meta()

        {:noreply,
         socket
         |> assign(:company, company)
         |> assign(:movies, [])
         |> assign(:meta, meta)
         |> assign(:params, page_params)
         |> assign(:search_term, params["search"] || "")
         |> assign(:sort_criteria, criteria)
         |> assign(:sort_direction, direction)
         |> assign(:sort_is_preset, sort_is_preset)
         |> assign(:active_lens_key, active_lens_key)
         |> assign_pagination(meta)
         |> assign_company_page_seo(company, [])
         |> put_flash(:error, "Unable to load movies")}
    end
  end

  @impl Phoenix.LiveView
  def handle_event(event, params, socket) do
    case Events.handle_event(event, params, socket) do
      :unknown -> super(event, params, socket)
      reply -> reply
    end
  end

  def company_logo_url(company) do
    cond do
      present?(company.logo_url) -> company.logo_url
      present?(company.logo_path) -> ProductionCompany.logo_url(company.logo_path, "w500")
      true -> nil
    end
  end

  def tmdb_company_url(company), do: "https://www.themoviedb.org/company/#{company.tmdb_id}"

  defp assign_company_page_seo(socket, company, movies) do
    path = "/companies/#{company.slug || company.id}"
    title = "#{company.name} Movies"

    description =
      "Browse #{company.name} movies on Cinegraph. Search, filter, and sort films connected to #{company.name}."

    socket
    |> assign(:page_title, title)
    |> assign(:meta_title, title)
    |> assign(:meta_description, description)
    |> assign(:meta_type, "website")
    |> assign(:canonical_url, "#{@site_url}#{path}")
    |> assign(:meta_url, "#{@site_url}#{path}")
    |> maybe_assign_meta_image(company, movies)
    |> assign(:json_ld, CinegraphWeb.SEO.item_list_schema(movies, title))
  end

  defp maybe_assign_meta_image(socket, company, movies) do
    case company_logo_url(company) do
      nil -> maybe_assign_movie_meta_image(socket, movies)
      url -> assign(socket, :meta_image, url)
    end
  end

  defp maybe_assign_movie_meta_image(socket, movies) do
    case Enum.find(movies, fn movie ->
           is_binary(movie.poster_path) and String.trim(movie.poster_path) != ""
         end) do
      %{poster_path: poster_path} ->
        assign(socket, :meta_image, "https://image.tmdb.org/t/p/w780#{poster_path}")

      _ ->
        socket
    end
  end

  defp empty_pagination_meta do
    %{
      total_count: 0,
      total_pages: 1,
      current_page: 1,
      page_size: 24
    }
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false
end

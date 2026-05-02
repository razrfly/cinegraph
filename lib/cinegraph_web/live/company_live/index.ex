defmodule CinegraphWeb.CompanyLive.Index do
  @moduledoc """
  LiveView for browsing production companies.
  """
  use CinegraphWeb, :live_view

  alias Cinegraph.Movies
  alias Cinegraph.Movies.ProductionCompany

  @categories ~w(all major international with-logos)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Companies")
     |> assign(:active_nav, "Companies")
     |> assign(:companies, [])
     |> assign(:category, "all")
     |> assign(:search, "")
     |> assign(:sort, "films")}
  end

  @impl true
  def handle_params(params, _url, socket) do
    category = normalize_category(params["category"])
    search = params["search"] || ""
    sort = params["sort"] || "films"

    companies =
      Movies.list_production_companies_with_stats(
        category: category,
        search: search,
        sort: sort
      )

    {:noreply,
     socket
     |> assign(:companies, companies)
     |> assign(:category, category)
     |> assign(:search, search)
     |> assign(:sort, sort)}
  end

  @impl true
  def handle_event("filter", params, socket) do
    query =
      params
      |> Map.take(["category", "search", "sort"])
      |> Enum.reject(fn {_key, value} -> value in [nil, "", "all", "films"] end)
      |> Map.new()

    {:noreply, push_patch(socket, to: ~p"/companies?#{query}")}
  end

  def company_logo_url(company) do
    cond do
      present?(company.logo_url) -> company.logo_url
      present?(company.logo_path) -> ProductionCompany.logo_url(company.logo_path, "w500")
      true -> nil
    end
  end

  defp normalize_category(category) when category in @categories, do: category
  defp normalize_category(_category), do: "all"

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false
end

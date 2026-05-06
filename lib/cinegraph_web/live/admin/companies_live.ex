defmodule CinegraphWeb.Admin.CompaniesLive do
  @moduledoc """
  Production-company admin index (#880 Phase 3).

  Different shape than the drift drilldowns — companies are a flat table with
  per-row coverage flags. Reads:

  - `Cinegraph.Maintenance.Companies.audit/0` — for the KPI strip
  - `Cinegraph.Movies.list_production_companies_with_stats/1` — for the table

  Per-row "Refresh metadata" enqueues `TMDbCompanyMetadataWorker` for that
  company. "Backfill all slugs" calls `Maintenance.Companies.backfill_slugs/0`.
  """
  use CinegraphWeb, :admin_live_view

  alias Cinegraph.Maintenance.Companies, as: CompaniesMaintenance
  alias Cinegraph.Movies
  alias Cinegraph.Workers.TMDbCompanyMetadataWorker

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Production companies")
     |> assign(:filter, "all")
     |> assign_data()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    filter = Map.get(params, "missing", "all")
    {:noreply, assign(socket, :filter, filter)}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, assign_data(socket)}
  end

  def handle_event("refresh_metadata", %{"id" => id_str}, socket) do
    with {id, _} <- Integer.parse(id_str),
         {:ok, %Oban.Job{id: job_id}} <-
           %{"company_id" => id} |> TMDbCompanyMetadataWorker.new() |> Oban.insert() do
      {:noreply, put_flash(socket, :info, "Enqueued metadata refresh as job ##{job_id}.")}
    else
      _ -> {:noreply, put_flash(socket, :error, "Failed to enqueue.")}
    end
  end

  def handle_event("backfill_all_slugs", _params, socket) do
    case CompaniesMaintenance.backfill_slugs() do
      {:ok, count} ->
        {:noreply,
         socket
         |> assign_data()
         |> put_flash(
           :info,
           "Backfilled #{count} slug#{if count == 1, do: "", else: "s"}."
         )}

      {:error, _company, changeset} ->
        {:noreply,
         put_flash(socket, :error, "Slug backfill failed: #{inspect(changeset.errors)}")}
    end
  end

  defp assign_data(socket) do
    audit =
      case CompaniesMaintenance.audit() do
        {:ok, map} -> map
        _ -> :error
      end

    companies =
      Movies.list_production_companies_with_stats(include_orphans: true, limit: 200)

    socket
    |> assign(:audit, audit)
    |> assign(:companies, companies)
    |> assign(:loaded_at, DateTime.utc_now())
  end

  defp filter_companies(companies, "all"), do: companies

  defp filter_companies(companies, "logo") do
    Enum.filter(companies, fn c -> not has_url?(c[:logo_url]) end)
  end

  defp filter_companies(companies, "slug") do
    Enum.filter(companies, fn c -> not has_url?(c[:slug]) end)
  end

  defp filter_companies(companies, "metadata") do
    Enum.filter(companies, fn c ->
      meta = Map.get(c, :metadata, %{}) || %{}
      tmdb = Map.get(meta, "tmdb", %{}) || %{}
      Map.get(tmdb, "company_details") == nil
    end)
  end

  defp filter_companies(companies, _), do: companies

  defp has_url?(nil), do: false
  defp has_url?(""), do: false
  defp has_url?(_), do: true

  @impl true
  def render(assigns) do
    filtered = filter_companies(assigns.companies, assigns.filter)
    assigns = assign(assigns, :filtered, filtered)

    ~H"""
    <.page_header
      title="Production companies"
      subtitle={"#{audit_total(@audit)} companies · last refreshed #{format_dt(@loaded_at)} UTC"}
    >
      <:actions>
        <button
          type="button"
          phx-click="backfill_all_slugs"
          data-confirm="Backfill slugs for all companies missing one. Continue?"
          class="text-sm font-semibold text-blue-700 hover:text-blue-900 underline"
        >
          Backfill all slugs
        </button>
        <button
          type="button"
          phx-click="refresh"
          class="text-sm text-gray-700 hover:text-gray-900 underline"
        >
          Refresh
        </button>
      </:actions>
    </.page_header>

    <%= if @audit != :error do %>
      <div class="grid grid-cols-2 sm:grid-cols-4 gap-4 mb-6">
        <.kpi_card title="Total" value={@audit.total_companies} accent={:zinc} />
        <.kpi_card
          title="With logo"
          value={@audit.companies_with_logo_url}
          accent={:green}
          subtitle={"of #{@audit.total_companies}"}
        />
        <.kpi_card
          title="With slug"
          value={@audit.companies_with_slugs}
          accent={:blue}
          subtitle={"of #{@audit.total_companies}"}
        />
        <.kpi_card
          title="With TMDb metadata"
          value={@audit.companies_with_tmdb_details_metadata}
          accent={:purple}
          subtitle={"of #{@audit.total_companies}"}
        />
      </div>
    <% end %>

    <.section_card>
      <div class="flex items-center gap-2 mb-4 flex-wrap">
        <span class="text-xs font-medium text-gray-700">Filter:</span>
        <%= for {label, key} <- [
          {"All", "all"},
          {"Missing logo", "logo"},
          {"Missing slug", "slug"},
          {"Missing metadata", "metadata"}
        ] do %>
          <.link
            patch={~p"/admin/companies?missing=#{key}"}
            class={filter_pill_class(@filter, key)}
          >
            {label}
          </.link>
        <% end %>
        <span class="ml-auto text-xs text-gray-500">{length(@filtered)} shown</span>
      </div>

      <%= if Enum.empty?(@filtered) do %>
        <p class="text-sm text-gray-500 py-8 text-center">No companies match this filter.</p>
      <% else %>
        <div class="overflow-x-auto">
          <table class="min-w-full divide-y divide-gray-200">
            <thead class="bg-gray-50">
              <tr>
                <th class="px-4 py-2 text-left text-xs font-medium text-gray-500 uppercase">
                  Logo
                </th>
                <th class="px-4 py-2 text-left text-xs font-medium text-gray-500 uppercase">
                  Name
                </th>
                <th class="px-4 py-2 text-right text-xs font-medium text-gray-500 uppercase">
                  TMDb id
                </th>
                <th class="px-4 py-2 text-right text-xs font-medium text-gray-500 uppercase">
                  Films
                </th>
                <th class="px-4 py-2 text-left text-xs font-medium text-gray-500 uppercase">
                  Slug
                </th>
                <th class="px-4 py-2 text-left text-xs font-medium text-gray-500 uppercase">
                  Metadata
                </th>
                <th class="px-4 py-2 text-right text-xs font-medium text-gray-500 uppercase"></th>
              </tr>
            </thead>
            <tbody class="bg-white divide-y divide-gray-100">
              <%= for c <- Enum.take(@filtered, 200) do %>
                <tr class="hover:bg-gray-50">
                  <td class="px-4 py-2">
                    <%= if has_url?(c[:logo_url]) do %>
                      <img
                        src={c[:logo_url]}
                        alt=""
                        class="h-8 w-8 object-contain bg-gray-50 rounded"
                      />
                    <% else %>
                      <span class="inline-flex items-center px-2 py-0.5 rounded-full text-xs font-medium bg-amber-100 text-amber-800">
                        none
                      </span>
                    <% end %>
                  </td>
                  <td class="px-4 py-2 text-sm">
                    <div class="font-medium text-gray-900">{c[:name]}</div>
                    <div class="text-xs text-gray-500">{c[:origin_country] || ""}</div>
                  </td>
                  <td class="px-4 py-2 text-right text-xs font-mono text-gray-600">
                    {c[:tmdb_id]}
                  </td>
                  <td class="px-4 py-2 text-right text-sm text-gray-700">
                    {c[:movie_count] || 0}
                  </td>
                  <td class="px-4 py-2 text-xs">
                    <%= if has_url?(c[:slug]) do %>
                      <code class="text-gray-600">{c[:slug]}</code>
                    <% else %>
                      <span class="inline-flex items-center px-2 py-0.5 rounded-full text-xs font-medium bg-red-100 text-red-800">
                        missing
                      </span>
                    <% end %>
                  </td>
                  <td class="px-4 py-2 text-xs">
                    <%= if has_metadata?(c) do %>
                      <span class="inline-flex items-center px-2 py-0.5 rounded-full text-xs font-medium bg-green-100 text-green-800">
                        ✓
                      </span>
                    <% else %>
                      <span class="inline-flex items-center px-2 py-0.5 rounded-full text-xs font-medium bg-amber-100 text-amber-800">
                        missing
                      </span>
                    <% end %>
                  </td>
                  <td class="px-4 py-2 text-right">
                    <button
                      type="button"
                      phx-click="refresh_metadata"
                      phx-value-id={c[:id]}
                      class="text-xs text-blue-700 hover:text-blue-900"
                    >
                      Refresh
                    </button>
                  </td>
                </tr>
              <% end %>
            </tbody>
          </table>
        </div>
      <% end %>
    </.section_card>
    """
  end

  defp audit_total(:error), do: "—"
  defp audit_total(%{total_companies: n}), do: n
  defp audit_total(_), do: "—"

  defp has_metadata?(c) do
    meta = Map.get(c, :metadata, %{}) || %{}
    tmdb = Map.get(meta, "tmdb", %{}) || %{}
    not is_nil(Map.get(tmdb, "company_details"))
  end

  defp filter_pill_class(active_filter, key) when active_filter == key do
    "inline-flex items-center px-3 py-1 rounded-full text-xs font-semibold bg-blue-600 text-white no-underline"
  end

  defp filter_pill_class(_active, _key) do
    "inline-flex items-center px-3 py-1 rounded-full text-xs font-medium bg-white text-gray-700 border border-gray-300 hover:bg-gray-50 no-underline"
  end

  defp format_dt(%DateTime{} = dt), do: Calendar.strftime(dt, "%H:%M:%S")
  defp format_dt(_), do: "—"
end

defmodule CinegraphWeb.Admin.DriftDomainLive do
  @moduledoc """
  Generic per-domain data-quality drilldown (#880 Phase 3).

  One LiveView module renders 5 different routes (`/admin/movies`,
  `/admin/people`, `/admin/ratings`, `/admin/availability`,
  `/admin/collaborations`) — Phoenix passes the route's `live_action` atom
  via `socket.assigns.live_action`, and the LiveView picks a config map
  from `domain_config/1`.

  Each page shows:

  - KPI strip from `Cinegraph.Health.Completeness.run/0`
  - Per-check `<.section_card>` with status pill, count + pct, and the
    drift module's 10 example rows
  - Bulk-action footer per check — checkbox each example, click "Run X for
    selected" → `Cinegraph.AdminHealth.Actions` enqueues the right worker

  Periodic refresh: 30s `Process.send_after`, mirroring AdminHealthLive's
  polling pattern.
  """
  use CinegraphWeb, :admin_live_view

  alias Cinegraph.Health.{Completeness, Drift, Verdict}
  alias CinegraphWeb.AdminHealth.Actions

  @refresh_interval 30_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Process.send_after(self(), :refresh, @refresh_interval)

    config = domain_config(socket.assigns.live_action)

    {:ok,
     socket
     |> assign(:page_title, config.title)
     |> assign(:config, config)
     |> assign(:selected, MapSet.new())
     |> assign_data()}
  end

  @impl true
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, @refresh_interval)
    {:noreply, assign_data(socket)}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, assign_data(socket, force: true)}
  end

  def handle_event("toggle_row", %{"check" => check, "id" => id}, socket) do
    key = {String.to_existing_atom(check), to_string(id)}
    selected = toggle(socket.assigns.selected, key)
    {:noreply, assign(socket, :selected, selected)}
  rescue
    _ -> {:noreply, socket}
  end

  def handle_event("clear_selection", _params, socket) do
    {:noreply, assign(socket, :selected, MapSet.new())}
  end

  def handle_event("run_bulk_action", %{"check" => check_str}, socket) do
    check = String.to_existing_atom(check_str)
    config = socket.assigns.config

    case Map.fetch(config.bulk_actions, check) do
      {:ok, {action_module, action_fun, _label}} ->
        ids =
          socket.assigns.selected
          |> Enum.filter(fn {c, _id} -> c == check end)
          |> Enum.map(fn {_c, id} -> id end)
          |> Enum.flat_map(fn id ->
            case Integer.parse(id) do
              {n, _} -> [n]
              _ -> []
            end
          end)

        if ids == [] do
          {:noreply, put_flash(socket, :error, "Select at least one row.")}
        else
          case apply(action_module, action_fun, [ids]) do
            {:ok, count} ->
              {:noreply,
               socket
               |> assign(:selected, MapSet.new())
               |> put_flash(:info, "Enqueued #{count} job#{if count == 1, do: "", else: "s"}.")}

            {:partial, %{ok: count, errors: errs}} ->
              {:noreply,
               socket
               |> assign(:selected, MapSet.new())
               |> put_flash(
                 :info,
                 "Enqueued #{count} jobs (#{length(errs)} errored)."
               )}

            {:error, reason} ->
              {:noreply, put_flash(socket, :error, "Failed: #{inspect(reason)}")}
          end
        end

      :error ->
        {:noreply, put_flash(socket, :error, "No bulk action wired for this check yet.")}
    end
  rescue
    _ -> {:noreply, socket}
  end

  defp toggle(set, key) do
    if MapSet.member?(set, key), do: MapSet.delete(set, key), else: MapSet.put(set, key)
  end

  defp assign_data(socket, opts \\ []) do
    config = socket.assigns.config

    socket
    |> assign(:checks, safe_drift(config.drift_module, opts))
    |> assign(:completeness, safe_completeness())
    |> assign(:loaded_at, DateTime.utc_now())
  end

  defp safe_drift(drift_module, opts) do
    case apply(drift_module, :all, [opts]) do
      [] ->
        []

      results when is_list(results) ->
        # Color each check via Verdict.compute/1 — pass a single-domain map
        # and extract the colored checks back out.
        domain_atom = List.first(results) |> Map.get(:domain) || :movies

        colored = Verdict.compute(%{domain_atom => results})

        case colored do
          %{domains: %{^domain_atom => %{checks: colored_checks}}} -> colored_checks
          _ -> results
        end

      other ->
        {:error, other}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp safe_completeness do
    Completeness.run()
  rescue
    _ -> :error
  end

  # =========================================================================
  # Render
  # =========================================================================

  @impl true
  def render(assigns) do
    ~H"""
    <.page_header title={@config.title} subtitle={@config.subtitle}>
      <:actions>
        <button
          type="button"
          phx-click="refresh"
          class="text-sm text-gray-700 hover:text-gray-900 underline"
        >
          Refresh
        </button>
      </:actions>
    </.page_header>

    <%= if @completeness != :error do %>
      <div class="grid grid-cols-2 sm:grid-cols-3 lg:grid-cols-5 gap-4 mb-6">
        <%= for {label, key, accent} <- @config.kpi_tiles do %>
          <.kpi_card
            title={label}
            value={kpi_value(@completeness, @config.completeness_root, key)}
            accent={accent}
            subtitle={kpi_subtitle(@completeness, @config.completeness_root, key)}
          />
        <% end %>
      </div>
    <% end %>

    <%= case @checks do %>
      <% {:error, msg} -> %>
        <.section_card>
          <p class="text-sm text-red-700">Failed to load drift checks: {msg}</p>
        </.section_card>
      <% checks when is_list(checks) -> %>
        <%= for check <- checks do %>
          <.section_card>
            <div class="flex items-start justify-between mb-3 gap-3">
              <div>
                <h3 class="text-base font-semibold text-gray-900 font-mono">
                  {format_check_label(check.check)}
                </h3>
                <p class="text-xs text-gray-500 mt-0.5">
                  <span class="font-mono">
                    {format_count(check.affected_count)}
                  </span>
                  of {format_count(check.total_population)}
                  <span class="text-gray-400">
                    ({format_pct(check.affected_pct)}%)
                  </span>
                </p>
              </div>
              <span class={"inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-semibold uppercase #{status_badge_class(check.status)}"}>
                {check.status}
              </span>
            </div>

            <p :if={check.blocked_reason} class="text-xs text-amber-700 italic mb-2">
              ⚠ {check.blocked_reason}
            </p>

            <%= if check.examples != [] do %>
              <details class="mt-2">
                <summary class="cursor-pointer text-sm text-blue-700 hover:text-blue-900">
                  {length(check.examples)} example row{if length(check.examples) == 1,
                    do: "",
                    else: "s"}
                </summary>

                <% bulk_action = Map.get(@config.bulk_actions, check.check) %>
                <% selected_count =
                  Enum.count(@selected, fn {c, _} -> c == check.check end) %>

                <div class="mt-3 overflow-x-auto">
                  <table class="min-w-full divide-y divide-gray-200 text-sm">
                    <thead class="bg-gray-50">
                      <tr>
                        <th :if={bulk_action} class="px-3 py-2 w-8"></th>
                        <th class="px-3 py-2 text-left text-xs font-medium text-gray-500 uppercase">
                          ID
                        </th>
                        <th class="px-3 py-2 text-left text-xs font-medium text-gray-500 uppercase">
                          Name / title
                        </th>
                        <th class="px-3 py-2 text-left text-xs font-medium text-gray-500 uppercase">
                          Reason
                        </th>
                      </tr>
                    </thead>
                    <tbody class="bg-white divide-y divide-gray-100">
                      <%= for ex <- check.examples do %>
                        <% id = Map.get(ex, :id) || Map.get(ex, "id") %>
                        <% name =
                          Map.get(ex, :name) || Map.get(ex, :title) || Map.get(ex, "name") ||
                            Map.get(ex, "title") || "—" %>
                        <% reason = Map.get(ex, :reason) || Map.get(ex, "reason") || "" %>
                        <tr>
                          <td :if={bulk_action} class="px-3 py-2">
                            <input
                              :if={id}
                              type="checkbox"
                              phx-click="toggle_row"
                              phx-value-check={check.check}
                              phx-value-id={id}
                              checked={MapSet.member?(@selected, {check.check, to_string(id)})}
                              class="rounded border-gray-300"
                            />
                          </td>
                          <td class="px-3 py-2 font-mono text-xs text-gray-700">
                            {id || "—"}
                          </td>
                          <td class="px-3 py-2 text-gray-900">{name}</td>
                          <td class="px-3 py-2 text-xs text-gray-500">{reason}</td>
                        </tr>
                      <% end %>
                    </tbody>
                  </table>
                </div>

                <div :if={bulk_action} class="mt-3 flex items-center gap-3 text-sm">
                  <% {_mod, _fun, label} = bulk_action %>
                  <span class="text-gray-600">{selected_count} selected</span>
                  <button
                    :if={selected_count > 0}
                    type="button"
                    phx-click="clear_selection"
                    class="text-xs text-gray-700 hover:text-gray-900 underline"
                  >
                    Clear
                  </button>
                  <button
                    type="button"
                    phx-click="run_bulk_action"
                    phx-value-check={check.check}
                    disabled={selected_count == 0}
                    class="ml-auto inline-flex items-center rounded-md bg-blue-600 px-3 py-1.5 text-xs font-semibold text-white hover:bg-blue-700 disabled:opacity-40 disabled:cursor-not-allowed"
                  >
                    {label}
                  </button>
                </div>
              </details>
            <% end %>
          </.section_card>
        <% end %>
      <% _ -> %>
        <.section_card>
          <p class="text-sm text-gray-500">No drift checks available.</p>
        </.section_card>
    <% end %>
    """
  end

  # =========================================================================
  # Domain configs — one per route's live_action
  # =========================================================================

  defp domain_config(:movies) do
    %{
      atom: :movies,
      title: "Movies",
      subtitle: "Movie metadata + external rating coverage",
      drift_module: Drift.Movies,
      completeness_root: :movies,
      kpi_tiles: [
        {"With OMDb", :with_omdb_pct, :green},
        {"With IMDb id", :with_imdb_id_pct, :blue}
      ],
      bulk_actions: %{
        missing_omdb: {Actions, :queue_omdb_refresh, "Queue OMDb refresh"},
        stale_omdb: {Actions, :queue_omdb_refresh, "Queue OMDb refresh"},
        missing_availability: {Actions, :queue_availability_refresh, "Queue availability refresh"}
      }
    }
  end

  defp domain_config(:people) do
    %{
      atom: :people,
      title: "People",
      subtitle: "Person profile, biography & PQS coverage",
      drift_module: Drift.People,
      completeness_root: :people,
      kpi_tiles: [
        {"With profile", :with_profile_pct, :blue},
        {"With biography", :with_biography_pct, :green},
        {"With known-for", :with_known_for_pct, :purple}
      ],
      bulk_actions: %{
        missing_profile_path: {Actions, :queue_person_tmdb_refresh, "Queue TMDb refresh"},
        missing_biography: {Actions, :queue_person_tmdb_refresh, "Queue TMDb refresh"},
        missing_known_for_department: {Actions, :queue_person_tmdb_refresh, "Queue TMDb refresh"},
        stale_record: {Actions, :queue_person_tmdb_refresh, "Queue TMDb refresh"}
      }
    }
  end

  defp domain_config(:ratings) do
    %{
      atom: :ratings,
      title: "Ratings",
      subtitle: "OMDb + RT + Metacritic external rating coverage",
      drift_module: Drift.Ratings,
      completeness_root: :movies,
      kpi_tiles: [
        {"With OMDb", :with_omdb_pct, :green}
      ],
      bulk_actions: %{
        omdb_null_backlog: {Actions, :queue_omdb_refresh, "Queue OMDb refresh"},
        omdb_stale: {Actions, :queue_omdb_refresh, "Queue OMDb refresh"}
      }
    }
  end

  defp domain_config(:availability) do
    %{
      atom: :availability,
      title: "Availability",
      subtitle: "Watch-availability provider coverage and freshness",
      drift_module: Drift.Availability,
      completeness_root: :movies,
      kpi_tiles: [],
      bulk_actions: %{
        availability_missing:
          {Actions, :queue_availability_refresh, "Queue availability refresh"},
        availability_stale: {Actions, :queue_availability_refresh, "Queue availability refresh"}
      }
    }
  end

  defp domain_config(:collaborations) do
    %{
      atom: :collaborations,
      title: "Collaborations",
      subtitle: "Collaboration graph health and queue state",
      drift_module: Drift.Collaborations,
      completeness_root: :festivals,
      kpi_tiles: [],
      bulk_actions: %{}
    }
  end

  defp domain_config(other), do: raise(ArgumentError, "unknown drift domain: #{inspect(other)}")

  # =========================================================================
  # Render helpers
  # =========================================================================

  defp kpi_value(:error, _root, _key), do: "—"

  defp kpi_value(completeness, root, key) when is_atom(root) and is_atom(key) do
    case completeness do
      %{^root => domain} when is_map(domain) ->
        value = Map.get(domain, key)
        format_pct_value(value)

      _ ->
        "—"
    end
  end

  defp kpi_subtitle(_completeness, _root, _key), do: nil

  defp format_pct_value(nil), do: "—"

  defp format_pct_value(value) when is_number(value) do
    "#{:erlang.float_to_binary(value * 1.0, decimals: 1)}%"
  end

  defp format_pct_value(_), do: "—"

  defp format_check_label(check) when is_atom(check) do
    check |> Atom.to_string() |> String.replace("_", " ")
  end

  defp format_check_label(check), do: to_string(check)

  defp format_count(nil), do: "0"

  defp format_count(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.graphemes()
    |> Enum.reverse()
    |> Enum.chunk_every(3)
    |> Enum.intersperse(",")
    |> List.flatten()
    |> Enum.reverse()
    |> Enum.join()
  end

  defp format_count(other), do: to_string(other)

  defp format_pct(nil), do: "0.0"
  defp format_pct(n) when is_number(n), do: :erlang.float_to_binary(n * 1.0, decimals: 2)
  defp format_pct(_), do: "—"

  defp status_badge_class(:green), do: "bg-green-100 text-green-800"
  defp status_badge_class(:amber), do: "bg-amber-100 text-amber-800"
  defp status_badge_class(:red), do: "bg-red-100 text-red-800"
  defp status_badge_class(_), do: "bg-zinc-100 text-zinc-700"
end

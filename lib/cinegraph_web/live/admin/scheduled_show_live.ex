defmodule CinegraphWeb.Admin.ScheduledShowLive do
  @moduledoc """
  Per-scheduled-worker drilldown at `/admin/scheduled/:id`.

  Shows the entry's schedule + queue + args, the last 24h of completed runs,
  and any failures from the last 24h. The id corresponds to a registered
  entry in `Cinegraph.Admin.JobRegistry`.

  Phase 1 of #880.
  """
  use CinegraphWeb, :admin_live_view

  alias Cinegraph.Admin.JobRegistry
  alias Cinegraph.Health.ObanReader

  @impl true
  def mount(%{"id" => id_str}, _session, socket) do
    case lookup_entry(id_str) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "No scheduled job with id '#{id_str}'.")
         |> push_navigate(to: ~p"/admin/scheduled")}

      entry ->
        ago_24h = DateTime.add(DateTime.utc_now(), -24 * 60 * 60)
        worker_str = inspect(entry.worker)

        {:ok,
         socket
         |> assign(:page_title, entry.label)
         |> assign(:entry, entry)
         |> assign(:since, ago_24h)
         |> assign(:recent_runs, safe_recent_runs(worker_str))
         |> assign(:discards, safe_discards(worker_str, ago_24h))}
    end
  end

  @impl true
  def handle_event("trigger", _params, socket) do
    case JobRegistry.enqueue!(socket.assigns.entry) do
      {:ok, %Oban.Job{id: job_id}} ->
        {:noreply,
         put_flash(
           socket,
           :info,
           "Enqueued #{socket.assigns.entry.label} as Oban job ##{job_id}."
         )}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to enqueue: #{inspect(reason)}")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.link
      navigate={~p"/admin/scheduled"}
      class="inline-block mb-4 text-sm text-blue-700 hover:text-blue-900"
    >
      ← Back to Scheduled jobs
    </.link>

    <.page_header title={@entry.label} subtitle={@entry.description}>
      <:actions>
        <button
          type="button"
          phx-click="trigger"
          data-confirm={confirm_message(@entry)}
          class="inline-flex items-center rounded-md bg-blue-600 px-3 py-1.5 text-xs font-semibold text-white hover:bg-blue-700"
        >
          Run now
        </button>
      </:actions>
    </.page_header>

    <.section_card title="Schedule">
      <dl class="grid grid-cols-1 gap-x-4 gap-y-3 sm:grid-cols-2">
        <div>
          <dt class="text-xs font-medium text-gray-500 uppercase">Worker</dt>
          <dd class="mt-1 text-sm font-mono text-gray-900">{inspect(@entry.worker)}</dd>
        </div>
        <div>
          <dt class="text-xs font-medium text-gray-500 uppercase">Queue</dt>
          <dd class="mt-1 text-sm font-mono text-gray-900">{@entry.queue}</dd>
        </div>
        <div>
          <dt class="text-xs font-medium text-gray-500 uppercase">Cron</dt>
          <dd class="mt-1 text-sm font-mono text-gray-900">{@entry.schedule}</dd>
        </div>
        <div>
          <dt class="text-xs font-medium text-gray-500 uppercase">Destination</dt>
          <dd class="mt-1 text-sm text-gray-900">{@entry.destination}</dd>
        </div>
        <div>
          <dt class="text-xs font-medium text-gray-500 uppercase">Mutating</dt>
          <dd class="mt-1 text-sm text-gray-900">
            <%= if @entry.mutating do %>
              <span class="inline-flex items-center px-2 py-0.5 rounded-full text-xs font-medium bg-amber-100 text-amber-800">
                Yes — writes data
              </span>
            <% else %>
              <span class="inline-flex items-center px-2 py-0.5 rounded-full text-xs font-medium bg-green-100 text-green-800">
                No — read-only
              </span>
            <% end %>
          </dd>
        </div>
        <div :if={@entry.args != %{}} class="sm:col-span-2">
          <dt class="text-xs font-medium text-gray-500 uppercase">Default args</dt>
          <dd class="mt-1 text-xs font-mono text-gray-700 bg-gray-50 rounded p-2">
            {inspect(@entry.args, pretty: true)}
          </dd>
        </div>
      </dl>
    </.section_card>

    <.section_card title={"Recent runs (last #{length_or_zero(@recent_runs)})"}>
      <%= cond do %>
        <% @recent_runs == :error -> %>
          <p class="text-sm text-red-600">
            Could not load recent runs. Check ObanReader logs.
          </p>
        <% Enum.empty?(@recent_runs) -> %>
          <CinegraphWeb.Admin.Components.AdminComponents.empty_state
            title="No runs yet."
            description="Click Run now to enqueue a one-off."
          />
        <% true -> %>
          <div class="overflow-x-auto">
            <table class="min-w-full divide-y divide-gray-200">
              <thead class="bg-gray-50">
                <tr>
                  <th class="px-4 py-2 text-left text-xs font-medium text-gray-500 uppercase">
                    Job
                  </th>
                  <th class="px-4 py-2 text-left text-xs font-medium text-gray-500 uppercase">
                    State
                  </th>
                  <th class="px-4 py-2 text-right text-xs font-medium text-gray-500 uppercase">
                    Attempt
                  </th>
                  <th class="px-4 py-2 text-right text-xs font-medium text-gray-500 uppercase">
                    Duration
                  </th>
                  <th class="px-4 py-2 text-left text-xs font-medium text-gray-500 uppercase">
                    Started
                  </th>
                  <th class="px-4 py-2 text-left text-xs font-medium text-gray-500 uppercase">
                    Last error
                  </th>
                </tr>
              </thead>
              <tbody class="bg-white divide-y divide-gray-200">
                <%= for run <- @recent_runs do %>
                  <tr>
                    <td class="px-4 py-2 text-xs font-mono text-gray-700">##{run.id}</td>
                    <td class="px-4 py-2 text-sm">
                      <span class={state_pill_class(run.state)}>{run.state}</span>
                    </td>
                    <td class="px-4 py-2 text-sm text-right text-gray-700">{run.attempt}</td>
                    <td class="px-4 py-2 text-sm text-right text-gray-700 font-mono">
                      {format_run_duration(run)}
                    </td>
                    <td class="px-4 py-2 text-sm text-gray-500">
                      {format_dt(run.attempted_at || run.scheduled_at || run.inserted_at)}
                    </td>
                    <td class="px-4 py-2 text-xs text-red-700 font-mono break-words max-w-md">
                      {format_error_short(run.last_error)}
                    </td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </div>
      <% end %>
    </.section_card>

    <.section_card title="Failures (last 24h)">
      <%= cond do %>
        <% @discards == :error -> %>
          <p class="text-sm text-red-600">
            Could not load discards. Check ObanReader logs.
          </p>
        <% Enum.empty?(@discards) -> %>
          <CinegraphWeb.Admin.Components.AdminComponents.empty_state title="No failures in the last 24 hours." />
        <% true -> %>
          <ul class="divide-y divide-gray-100">
            <%= for d <- @discards do %>
              <li class="py-3">
                <div class="flex items-baseline justify-between gap-4">
                  <div class="text-xs font-mono text-gray-500">job ##{d.id}</div>
                  <div class="text-xs text-gray-500">
                    attempt {d.attempt} · {format_dt(d.discarded_at)}
                  </div>
                </div>
                <div class="mt-1 text-sm text-red-700 font-mono break-words">
                  {format_error(d.last_error)}
                </div>
              </li>
            <% end %>
          </ul>
      <% end %>
    </.section_card>

    <.section_card title="Related">
      <p class="text-sm text-gray-600 mb-2">
        This worker affects the <span class="font-medium text-gray-900">{@entry.destination}</span>
        domain. Drilldown links land in Phase 3 (#880).
      </p>
      <div class="flex flex-wrap gap-2">
        <.link
          navigate={~p"/admin/health"}
          class="inline-flex items-center rounded-md border border-gray-300 px-3 py-1.5 text-sm text-gray-700 hover:bg-gray-50"
        >
          → Homeostasis dashboard
        </.link>
        <.link
          navigate={~p"/admin/oban"}
          class="inline-flex items-center rounded-md border border-gray-300 px-3 py-1.5 text-sm text-gray-700 hover:bg-gray-50"
        >
          → Oban Web ({@entry.queue} queue)
        </.link>
      </div>
    </.section_card>
    """
  end

  defp confirm_message(%{mutating: true, label: label}),
    do: "This will mutate data. Run #{label} now?"

  defp confirm_message(_), do: nil

  defp lookup_entry(id_str) do
    JobRegistry.by_id(String.to_existing_atom(id_str))
  rescue
    ArgumentError -> nil
  end

  defp safe_recent_runs(worker_str) do
    ObanReader.recent_runs_for_worker(worker_str, 50)
  rescue
    _ -> :error
  end

  defp safe_discards(worker_str, since) do
    ObanReader.discards_for_queue([worker: worker_str], since)
  rescue
    _ -> :error
  end

  defp length_or_zero(list) when is_list(list), do: length(list)
  defp length_or_zero(_), do: 0

  defp state_pill_class("completed"),
    do:
      "inline-flex items-center px-2 py-0.5 rounded-full text-xs font-medium bg-green-100 text-green-800"

  defp state_pill_class("executing"),
    do:
      "inline-flex items-center px-2 py-0.5 rounded-full text-xs font-medium bg-blue-100 text-blue-800"

  defp state_pill_class("retryable"),
    do:
      "inline-flex items-center px-2 py-0.5 rounded-full text-xs font-medium bg-amber-100 text-amber-800"

  defp state_pill_class("discarded"),
    do:
      "inline-flex items-center px-2 py-0.5 rounded-full text-xs font-medium bg-red-100 text-red-800"

  defp state_pill_class("cancelled"),
    do:
      "inline-flex items-center px-2 py-0.5 rounded-full text-xs font-medium bg-orange-100 text-orange-800"

  defp state_pill_class("scheduled"),
    do:
      "inline-flex items-center px-2 py-0.5 rounded-full text-xs font-medium bg-gray-100 text-gray-700"

  defp state_pill_class(_),
    do:
      "inline-flex items-center px-2 py-0.5 rounded-full text-xs font-medium bg-gray-100 text-gray-700"

  defp format_run_duration(%{state: "completed", attempted_at: a, completed_at: c})
       when not is_nil(a) and not is_nil(c) do
    diff = DateTime.diff(c, a, :millisecond)
    format_ms(diff)
  end

  defp format_run_duration(%{state: "executing", attempted_at: a}) when not is_nil(a) do
    diff = DateTime.diff(DateTime.utc_now(), a, :millisecond)
    format_ms(diff) <> " (running)"
  end

  defp format_run_duration(_), do: "—"

  defp format_ms(ms) when is_integer(ms) and ms < 1000, do: "#{ms}ms"
  defp format_ms(ms) when is_integer(ms) and ms < 60_000, do: "#{Float.round(ms / 1000, 1)}s"
  defp format_ms(ms) when is_integer(ms), do: "#{div(ms, 60_000)}m #{div(rem(ms, 60_000), 1000)}s"

  defp format_error_short(nil), do: ""
  defp format_error_short(err) when is_binary(err), do: String.slice(err, 0, 200)
  defp format_error_short(err), do: inspect(err) |> String.slice(0, 200)

  defp format_dt(nil), do: "—"
  defp format_dt(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M UTC")
  defp format_dt(_), do: "—"

  defp format_error(nil), do: "(no error message)"
  defp format_error(err) when is_binary(err), do: String.slice(err, 0, 500)
  defp format_error(err), do: inspect(err) |> String.slice(0, 500)
end

defmodule CinegraphWeb.Admin.ScheduledLive do
  @moduledoc """
  Admin index of every scheduled job in `Cinegraph.Admin.JobRegistry`.

  Renders the 24 cron entries as a table with a "Trigger Now" button per row.
  Triggering enqueues a one-off run via `Oban.insert/1` using the entry's
  registered default args.

  Phase 1 of #880.
  """
  use CinegraphWeb, :admin_live_view

  alias Cinegraph.Admin.JobRegistry

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Scheduled jobs")
     |> assign(:entries, JobRegistry.scheduled())
     |> assign(:filter, "")
     |> assign(:show_args, false)}
  end

  @impl true
  def handle_event("filter", %{"q" => q}, socket) do
    {:noreply, assign(socket, :filter, q)}
  end

  def handle_event("toggle_args", _params, socket) do
    {:noreply, update(socket, :show_args, &Kernel.!/1)}
  end

  def handle_event("clear_filter", _params, socket) do
    {:noreply, assign(socket, :filter, "")}
  end

  def handle_event("trigger", %{"id" => id_str}, socket) do
    with {id_atom, ""} <- {String.to_existing_atom(id_str), ""},
         entry when not is_nil(entry) <- JobRegistry.by_id(id_atom),
         {:ok, %Oban.Job{id: job_id}} <- JobRegistry.enqueue!(entry) do
      {:noreply,
       put_flash(
         socket,
         :info,
         "Enqueued #{entry.label} as Oban job ##{job_id}."
       )}
    else
      nil ->
        {:noreply, put_flash(socket, :error, "Unknown job id.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to enqueue: #{inspect(reason)}")}

      _ ->
        {:noreply, put_flash(socket, :error, "Failed to enqueue.")}
    end
  rescue
    ArgumentError ->
      {:noreply, put_flash(socket, :error, "Unknown job id.")}
  end

  @impl true
  def render(assigns) do
    filtered = filter_entries(assigns.entries, assigns.filter)
    assigns = assign(assigns, :filtered, filtered)

    ~H"""
    <.page_header
      title="Scheduled jobs"
      subtitle={"#{length(@entries)} cron entries — Trigger Now enqueues a one-off run with the registered default args."}
    >
      <:actions>
        <button
          type="button"
          phx-click="toggle_args"
          class="text-sm text-gray-700 hover:text-gray-900 underline"
        >
          {if @show_args, do: "Hide args", else: "Show args"}
        </button>
      </:actions>
    </.page_header>

    <.section_card>
      <form phx-change="filter" class="mb-4 flex gap-2">
        <input
          type="text"
          name="q"
          value={@filter}
          placeholder="Filter by label, worker, or queue…"
          class="flex-1 rounded-md border-gray-300 text-sm focus:border-blue-500 focus:ring-blue-500"
        />
        <button
          :if={@filter != ""}
          type="button"
          phx-click="clear_filter"
          class="rounded-md border border-gray-300 px-3 py-1 text-sm text-gray-700 hover:bg-gray-50"
        >
          Clear
        </button>
      </form>

      <%= if Enum.empty?(@filtered) do %>
        <CinegraphWeb.Admin.Components.AdminComponents.empty_state
          title="No scheduled jobs match"
          description="Clear the filter to see all 24 entries."
        />
      <% else %>
        <div class="overflow-x-auto">
          <table class="min-w-full divide-y divide-gray-200">
            <thead class="bg-gray-50">
              <tr>
                <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                  Worker
                </th>
                <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                  Queue
                </th>
                <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                  Cron
                </th>
                <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                  Destination
                </th>
                <th class="px-4 py-3 text-right text-xs font-medium text-gray-500 uppercase tracking-wider">
                  Action
                </th>
              </tr>
            </thead>
            <tbody class="bg-white divide-y divide-gray-200">
              <%= for entry <- @filtered do %>
                <tr class="hover:bg-gray-50">
                  <td class="px-4 py-3 whitespace-nowrap text-sm">
                    <.link
                      navigate={~p"/admin/scheduled/#{entry.id}"}
                      class="font-medium text-blue-700 hover:text-blue-900"
                    >
                      {entry.label}
                    </.link>
                    <div class="text-xs text-gray-500 font-mono">
                      {inspect(entry.worker)}
                    </div>
                    <div class="text-xs text-gray-500 mt-0.5">
                      {entry.description}
                    </div>
                    <div
                      :if={@show_args && entry.args != %{}}
                      class="mt-1 text-xs font-mono text-gray-600 bg-gray-50 rounded p-2"
                    >
                      {inspect(entry.args)}
                    </div>
                  </td>
                  <td class="px-4 py-3 whitespace-nowrap text-sm text-gray-700">
                    <code class="text-xs">{entry.queue}</code>
                  </td>
                  <td class="px-4 py-3 whitespace-nowrap text-sm text-gray-700">
                    <code class="text-xs">{entry.schedule}</code>
                  </td>
                  <td class="px-4 py-3 whitespace-nowrap text-sm text-gray-600">
                    {entry.destination}
                  </td>
                  <td class="px-4 py-3 whitespace-nowrap text-right">
                    <button
                      type="button"
                      phx-click="trigger"
                      phx-value-id={entry.id}
                      data-confirm={confirm_message(entry)}
                      class="inline-flex items-center rounded-md bg-blue-600 px-3 py-1.5 text-xs font-semibold text-white hover:bg-blue-700"
                    >
                      Run now
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

  defp confirm_message(%{mutating: true, label: label}),
    do: "This will mutate data. Run #{label} now?"

  defp confirm_message(_), do: nil

  defp filter_entries(entries, ""), do: entries

  defp filter_entries(entries, filter) do
    needle = String.downcase(filter)

    Enum.filter(entries, fn entry ->
      String.contains?(String.downcase(entry.label), needle) or
        String.contains?(String.downcase(inspect(entry.worker)), needle) or
        String.contains?(String.downcase(to_string(entry.queue)), needle) or
        String.contains?(String.downcase(entry.description), needle)
    end)
  end
end

defmodule CinegraphWeb.Admin.AuditsLive do
  @moduledoc """
  Audits admin index (#880 Phase 3).

  Registry-driven tabs page surfacing every entry in `Cinegraph.Admin.AuditRegistry`
  as a clickable tab. Each tab has a "Run audit" button; required-arg audits
  (e.g., `:imdb_event_id` needing event_id, `:queue_failures` needing queue) get
  a small inline form. Result is rendered as pretty-printed JSON for Phase 3 —
  bespoke renderers per audit can come later.

  Slow audits (`:imdb_event_id`, `:imdb_list_pagination`) use `start_async`
  so the UI doesn't block.
  """
  use CinegraphWeb, :admin_live_view

  alias Cinegraph.Admin.AuditRegistry

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Audits")
     |> assign(:entries, AuditRegistry.all())
     |> assign(:active_id, nil)
     |> assign(:result, nil)
     |> assign(:running, false)
     |> assign(:form_state, %{})}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    case params["audit"] do
      nil ->
        first = List.first(socket.assigns.entries) || %{id: nil}
        {:noreply, assign(socket, :active_id, first.id)}

      id_str ->
        active = String.to_existing_atom(id_str)

        {:noreply,
         socket
         |> assign(:active_id, active)
         |> assign(:result, nil)}
    end
  rescue
    ArgumentError ->
      {:noreply, socket}
  end

  @impl true
  def handle_event("select", %{"id" => id}, socket) do
    {:noreply, push_patch(socket, to: ~p"/admin/audits?audit=#{id}")}
  end

  def handle_event("set_form", %{"key" => key, "value" => value}, socket) do
    new_state = Map.put(socket.assigns.form_state, key, value)
    {:noreply, assign(socket, :form_state, new_state)}
  end

  def handle_event("run", _params, socket) do
    entry = active_entry(socket)
    runtime_opts = build_runtime_opts(entry, socket.assigns.form_state)

    cond do
      entry == nil ->
        {:noreply, socket}

      entry.speed == :slow ->
        {:noreply,
         socket
         |> assign(:running, true)
         |> assign(:result, nil)
         |> start_async(:run_audit, fn -> AuditRegistry.run(entry.id, runtime_opts) end)}

      true ->
        result = AuditRegistry.run(entry.id, runtime_opts)
        {:noreply, assign(socket, :result, result)}
    end
  end

  @impl true
  def handle_async(:run_audit, {:ok, value}, socket) do
    {:noreply, socket |> assign(:running, false) |> assign(:result, value)}
  end

  def handle_async(:run_audit, {:exit, reason}, socket) do
    {:noreply,
     socket
     |> assign(:running, false)
     |> assign(:result, {:error, {:exit, reason}})}
  end

  defp active_entry(%Phoenix.LiveView.Socket{assigns: %{active_id: id}}),
    do: AuditRegistry.by_id(id)

  defp active_entry(%{active_id: id}), do: AuditRegistry.by_id(id)
  defp active_entry(_), do: nil

  defp build_runtime_opts(nil, _form), do: []

  defp build_runtime_opts(entry, form) do
    case entry do
      %{arity: :required} = entry ->
        case Map.get(form, required_arg_key(entry)) do
          nil -> []
          "" -> []
          val -> [required_arg: val]
        end

      %{id: :queue_failures} ->
        # queue_failures expects :queue or :worker
        opts = []

        opts =
          case Map.get(form, "queue") do
            nil ->
              opts

            "" ->
              opts

            v ->
              case safe_to_existing_atom(v) do
                {:ok, atom} -> [{:queue, atom} | opts]
                :error -> opts
              end
          end

        opts =
          case Map.get(form, "worker") do
            nil -> opts
            "" -> opts
            v -> [{:worker, v} | opts]
          end

        opts

      _ ->
        []
    end
  end

  defp required_arg_key(%{id: :imdb_event_id}), do: "event_id"
  defp required_arg_key(%{id: id}), do: Atom.to_string(id)

  defp required_arg_label(%{id: :imdb_event_id}), do: "IMDb event id"

  defp required_arg_label(%{label: label}) do
    label
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp required_arg_label(%{id: id}), do: Atom.to_string(id)

  defp required_arg_placeholder(%{id: :imdb_event_id}), do: "ev0000003"
  defp required_arg_placeholder(%{id: id}), do: Atom.to_string(id)

  defp safe_to_existing_atom(value) do
    {:ok, String.to_existing_atom(value)}
  rescue
    ArgumentError -> :error
  end

  defp people_scores_navigation(assigns) do
    ~H"""
    <div :if={@active.id == :people_scores} class="mb-4 text-xs">
      <.link
        navigate={~p"/admin/predictions"}
        class="text-blue-600 hover:text-blue-800 inline-flex items-center gap-1"
      >
        <span>← Back to predictions (auteurs criterion)</span>
      </.link>
    </div>
    """
  end

  @impl true
  def render(assigns) do
    active = active_entry(assigns)
    assigns = assign(assigns, :active, active)

    ~H"""
    <.page_header
      title="Audits"
      subtitle="Run any of the registered audit modules from the UI."
    />

    <%!-- Tabs --%>
    <div class="border-b border-gray-200 mb-6 -mx-6 px-6 overflow-x-auto">
      <nav class="-mb-px flex gap-6" role="tablist">
        <%= for entry <- @entries do %>
          <% active? = @active_id == entry.id %>
          <button
            type="button"
            role="tab"
            aria-selected={to_string(active?)}
            phx-click="select"
            phx-value-id={entry.id}
            class={[
              "whitespace-nowrap py-3 px-1 border-b-2 font-medium text-sm flex items-center gap-2",
              active? && "border-blue-500 text-blue-600",
              !active? && "border-transparent text-gray-500 hover:text-gray-700 hover:border-gray-300"
            ]}
          >
            <span>{entry.label}</span>
            <span :if={entry.speed == :slow} class="text-[10px] text-amber-700 uppercase">
              slow
            </span>
          </button>
        <% end %>
      </nav>
    </div>

    <%= if @active do %>
      <.section_card title={@active.label}>
        <p class="text-sm text-gray-600 mb-4">{@active.description}</p>

        <.people_scores_navigation active={@active} />

        <%!-- Args form for required-arg audits --%>
        <%= if @active.arity == :required or @active.id == :queue_failures do %>
          <div class="bg-gray-50 border border-gray-200 rounded-md p-4 mb-4 space-y-3">
            <p class="text-xs font-semibold text-gray-700 uppercase">Required arguments</p>
            <%= if @active.arity == :required do %>
              <input
                type="text"
                phx-blur="set_form"
                phx-value-key={required_arg_key(@active)}
                value={@form_state[required_arg_key(@active)]}
                placeholder={required_arg_placeholder(@active)}
                class="w-full rounded-md border-gray-300 text-sm font-mono"
              />
              <p class="text-xs text-gray-500">
                {required_arg_label(@active)}
                <span :if={@active.id == :imdb_event_id}>
                  (looks like <code>ev0000003</code>)
                </span>
              </p>
            <% end %>
            <%= if @active.id == :queue_failures do %>
              <div class="grid grid-cols-2 gap-3">
                <div>
                  <label class="block text-xs font-medium text-gray-700 mb-1">Queue (optional)</label>
                  <input
                    type="text"
                    phx-blur="set_form"
                    phx-value-key="queue"
                    value={@form_state["queue"]}
                    placeholder="tmdb"
                    class="w-full rounded-md border-gray-300 text-sm font-mono"
                  />
                </div>
                <div>
                  <label class="block text-xs font-medium text-gray-700 mb-1">
                    Worker (optional)
                  </label>
                  <input
                    type="text"
                    phx-blur="set_form"
                    phx-value-key="worker"
                    value={@form_state["worker"]}
                    placeholder="Cinegraph.Workers.OMDbEnrichmentWorker"
                    class="w-full rounded-md border-gray-300 text-sm font-mono"
                  />
                </div>
              </div>
              <p class="text-xs text-gray-500">
                Provide either <code>queue</code> or <code>worker</code>.
              </p>
            <% end %>
          </div>
        <% end %>

        <button
          type="button"
          phx-click="run"
          disabled={@running}
          class="inline-flex items-center rounded-md bg-blue-600 px-4 py-2 text-sm font-semibold text-white hover:bg-blue-700 disabled:opacity-40"
        >
          {if @running, do: "Running…", else: "Run audit"}
        </button>

        <div :if={@result != nil} class="mt-6">
          <h4 class="text-sm font-semibold text-gray-900 mb-2">Result</h4>
          <%= case @result do %>
            <% {:ok, map} -> %>
              <pre class="bg-gray-50 border border-gray-200 rounded-md p-4 text-xs font-mono overflow-x-auto max-h-[600px] overflow-y-auto"><code>{format_result(map)}</code></pre>
            <% {:error, reason} -> %>
              <div class="bg-red-50 border border-red-200 rounded-md p-4 text-sm text-red-800">
                Error: <span class="font-mono text-xs">{inspect(reason)}</span>
              </div>
            <% other -> %>
              <pre class="bg-gray-50 border border-gray-200 rounded-md p-4 text-xs font-mono overflow-x-auto"><code>{inspect(other, pretty: true)}</code></pre>
          <% end %>
        </div>
      </.section_card>
    <% else %>
      <.section_card>
        <p class="text-sm text-gray-500">No audit selected.</p>
      </.section_card>
    <% end %>
    """
  end

  defp format_result(map) when is_map(map) do
    case Jason.encode(map, pretty: true) do
      {:ok, json} -> json
      _ -> inspect(map, pretty: true, limit: :infinity)
    end
  end

  defp format_result(other), do: inspect(other, pretty: true)
end

defmodule CinegraphWeb.GlobalSearchLive do
  @moduledoc """
  Nested LiveView mounted in the V2 root layout that powers the typeahead
  in the top nav. Calls `Cinegraph.Search.global/2` directly (in-process),
  renders grouped results with image previews, and degrades gracefully
  when JS is unavailable.

  Variants:
    * `:compact`  — desktop dropdown anchored under the nav input (default)
    * `:sheet`    — mobile full-screen overlay (M2 polish, see Task 13)
  """

  use CinegraphWeb, :live_view

  alias Cinegraph.Search
  import CinegraphWeb.GlobalSearch.Components

  @min_query_length 2

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:query, "")
     |> assign(:variant, :compact)
     |> assign(:open?, false)
     |> assign(:recents, [])
     |> assign(:min_query_length, @min_query_length)
     |> assign(:results, empty_results())
     |> assign(:async_state, :idle), layout: false}
  end

  @impl true
  def handle_event("change", %{"q" => raw}, socket) do
    query = raw |> to_string() |> String.trim()

    if String.length(query) < @min_query_length do
      {:noreply,
       socket
       |> assign(:query, raw)
       |> assign(:async_state, :idle)
       |> assign(:results, empty_results())}
    else
      {:noreply,
       socket
       |> assign(:query, raw)
       |> assign(:async_state, :loading)
       |> start_async(:search, fn -> Search.global(query, limit: 5) end)}
    end
  end

  def handle_event("focus", _params, socket) do
    {:noreply, assign(socket, :open?, true)}
  end

  def handle_event("blur", _params, socket) do
    # Slight delay would be nice for click-through, but for v1 just close.
    {:noreply, assign(socket, :open?, false)}
  end

  def handle_event("update_recents", %{"recents" => recents}, socket)
      when is_list(recents) do
    {:noreply, assign(socket, :recents, Enum.take(recents, 5))}
  end

  def handle_event("update_recents", _, socket), do: {:noreply, socket}

  @impl true
  def handle_async(:search, {:ok, results}, socket) do
    {:noreply,
     socket
     |> assign(:results, results)
     |> assign(:async_state, :ok)}
  end

  def handle_async(:search, {:exit, _reason}, socket) do
    {:noreply,
     socket
     |> assign(:results, empty_results())
     |> assign(:async_state, :error)}
  end

  defp empty_results,
    do: %{films: [], people: [], lists: [], companies: [], total_count: 0}

  # ============================================================================
  # Render
  # ============================================================================

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id="global-search"
      class="relative w-full"
      phx-hook="GlobalSearch"
      data-min-length={@min_query_length}
    >
      <form phx-change="change" phx-submit="change" autocomplete="off">
        <div class={[
          "relative flex items-center bg-mist-50 dark:bg-white/5 rounded-lg transition-colors",
          "h-9 px-3",
          if(@open?,
            do:
              "border border-mist-950 dark:border-white shadow-[0_0_0_3px_rgba(0,0,0,.04)] dark:shadow-[0_0_0_3px_rgba(255,255,255,.05)]",
            else: "border border-mist-950/15 dark:border-white/15"
          )
        ]}>
          <svg
            width="13"
            height="13"
            viewBox="0 0 16 16"
            fill="none"
            class="shrink-0 text-mist-500"
          >
            <circle cx="7" cy="7" r="5" stroke="currentColor" stroke-width="1.4" />
            <path d="M11 11 L14 14" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" />
          </svg>
          <input
            id="global-search-input"
            type="text"
            name="q"
            value={@query}
            placeholder="Search films, people, lists, companies…"
            phx-debounce="200"
            role="combobox"
            aria-haspopup="listbox"
            aria-expanded={if dropdown_visible?(assigns), do: "true", else: "false"}
            aria-controls="global-search-listbox"
            aria-autocomplete="list"
            class="flex-1 ml-0.5 text-[13px] text-mist-950 dark:text-white placeholder:text-mist-500 dark:placeholder:text-mist-400 bg-transparent border-0 outline-none focus:outline-none focus:ring-0 focus:shadow-none min-w-0 font-[inherit] appearance-none"
          />
        </div>
      </form>

      <%= if dropdown_visible?(assigns) do %>
        <div
          id="global-search-listbox"
          role="listbox"
          class="absolute top-[calc(100%+6px)] left-0 right-0 bg-white dark:bg-mist-900 rounded-lg border border-mist-950/10 dark:border-white/10 shadow-[0_8px_32px_rgba(0,0,0,.08)] dark:shadow-[0_8px_32px_rgba(0,0,0,.5)] overflow-hidden z-10 max-h-[70vh] overflow-y-auto"
        >
          <%= cond do %>
            <% String.trim(@query) == "" and @recents != [] -> %>
              {render_recents(assigns)}
            <% @async_state == :loading -> %>
              {render_skeleton(assigns)}
            <% @async_state == :error -> %>
              <p class="px-4 py-6 text-[13px] text-mist-700 dark:text-mist-400">
                Search is having a moment. Try again in a sec.
              </p>
            <% @results.total_count == 0 -> %>
              <p class="px-4 py-6 text-[13px] text-mist-700 dark:text-mist-400">
                No matches. Try a film title, actor, director, or list.
              </p>
            <% true -> %>
              {render_results(assigns)}
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  # Show the dropdown whenever there's something to show:
  #  - explicitly opened (focus event, recents panel), OR
  #  - the query is at least @min_query_length chars (real search results).
  #
  # Below the min length we render nothing so we don't flash a "No matches"
  # state for a single character that was below threshold anyway.
  defp dropdown_visible?(%{open?: true}), do: true

  defp dropdown_visible?(%{query: q}) when is_binary(q),
    do: String.length(String.trim(q)) >= @min_query_length

  defp dropdown_visible?(_), do: false
end

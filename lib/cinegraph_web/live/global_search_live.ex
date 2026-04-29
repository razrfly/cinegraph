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

  alias Cinegraph.Movies.{Movie, ProductionCompany}
  alias Cinegraph.Search

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
        <div
          role="combobox"
          aria-haspopup="listbox"
          aria-expanded={if dropdown_visible?(assigns), do: "true", else: "false"}
          aria-owns="global-search-listbox"
          class={[
            "relative flex items-center bg-mist-50 rounded-lg transition-colors",
            "h-9 px-3",
            if(@open?,
              do: "border border-mist-950 shadow-[0_0_0_3px_rgba(0,0,0,.04)]",
              else: "border border-mist-950/15"
            )
          ]}
        >
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
            phx-focus="focus"
            phx-blur="blur"
            role="searchbox"
            aria-controls="global-search-listbox"
            aria-autocomplete="list"
            class="flex-1 ml-[9px] text-[13px] text-mist-950 bg-transparent border-0 outline-none min-w-0 font-[inherit]"
          />
        </div>
      </form>

      <%= if dropdown_visible?(assigns) do %>
        <div
          id="global-search-listbox"
          role="listbox"
          phx-mousedown-prevent
          class="absolute top-[calc(100%+6px)] left-0 right-0 bg-white rounded-lg border border-mist-950/10 shadow-[0_8px_32px_rgba(0,0,0,.08)] overflow-hidden z-10 max-h-[70vh] overflow-y-auto"
        >
          <%= cond do %>
            <% String.trim(@query) == "" and @recents != [] -> %>
              {render_recents(assigns)}
            <% @async_state == :loading -> %>
              {render_skeleton(assigns)}
            <% @async_state == :error -> %>
              <p class="px-4 py-6 text-[13px] text-mist-700">
                Search is having a moment. Try again in a sec.
              </p>
            <% @results.total_count == 0 -> %>
              <p class="px-4 py-6 text-[13px] text-mist-700">
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
    do: String.length(q) >= @min_query_length

  defp dropdown_visible?(_), do: false

  defp render_recents(assigns) do
    ~H"""
    <ul class="py-2">
      <li class="px-4 pt-2 pb-1 text-[10.5px] uppercase tracking-[.08em] text-mist-500 font-semibold">
        Recent
      </li>
      <li :for={r <- @recents} class="px-2">
        <a
          href={r["href"]}
          class="flex items-center gap-2 px-2 py-2 rounded-md text-[13px] text-mist-950 hover:bg-mist-50 no-underline"
        >
          <span class="text-mist-500" aria-hidden="true">🕘</span>
          {r["label"]}
        </a>
      </li>
    </ul>
    """
  end

  defp render_skeleton(assigns) do
    ~H"""
    <div class="py-2">
      <div :for={_ <- 1..3} class="flex items-center gap-3 px-4 py-2">
        <div class="w-10 h-10 rounded-md bg-mist-100 animate-pulse" />
        <div class="flex-1 space-y-1">
          <div class="h-3 w-3/4 bg-mist-100 rounded animate-pulse" />
          <div class="h-2 w-1/2 bg-mist-100 rounded animate-pulse" />
        </div>
      </div>
    </div>
    """
  end

  defp render_results(assigns) do
    ~H"""
    <div class="py-2 divide-y divide-mist-950/[0.06]">
      <.section :if={@results.films != []} title="Films">
        <:row :for={f <- @results.films}>
          <.film_row film={f} />
        </:row>
      </.section>

      <.section :if={@results.people != []} title="People">
        <:row :for={p <- @results.people}>
          <.person_row person={p} />
        </:row>
      </.section>

      <.section :if={@results.lists != []} title="Lists">
        <:row :for={l <- @results.lists}>
          <.list_row list={l} />
        </:row>
      </.section>

      <.section :if={@results.companies != []} title="Companies">
        <:row :for={c <- @results.companies}>
          <.company_row company={c} />
        </:row>
      </.section>
    </div>
    """
  end

  attr :title, :string, required: true
  slot :row

  defp section(assigns) do
    ~H"""
    <section class="py-1">
      <div class="px-4 pt-2 pb-1 text-[10.5px] uppercase tracking-[.08em] text-mist-500 font-semibold">
        {@title}
      </div>
      <ul class="px-2">
        <li :for={r <- @row} class="px-0">{render_slot(r)}</li>
      </ul>
    </section>
    """
  end

  attr :film, :map, required: true

  defp film_row(assigns) do
    ~H"""
    <a
      href={"/movies/" <> @film.slug}
      role="option"
      class="flex items-center gap-3 px-2 py-2 rounded-md hover:bg-mist-50 no-underline"
    >
      <div class="w-10 h-[60px] rounded bg-mist-100 overflow-hidden shrink-0 grid place-items-center">
        <img
          :if={@film.poster_path}
          src={Movie.image_url(@film.poster_path, "w92")}
          alt=""
          loading="lazy"
          decoding="async"
          class="w-full h-full object-cover"
        />
        <span :if={!@film.poster_path} class="text-mist-400 text-lg" aria-hidden="true">🎬</span>
      </div>
      <div class="flex-1 min-w-0">
        <div class="text-[13.5px] text-mist-950 truncate">{@film.title}</div>
        <div class="text-[11.5px] text-mist-500 truncate">
          <span :if={@film.year}>{@film.year}</span>
          <span :if={@film.year && @film.director}> · </span>
          <span :if={@film.director}>dir. {@film.director}</span>
        </div>
      </div>
    </a>
    """
  end

  attr :person, :map, required: true

  defp person_row(assigns) do
    ~H"""
    <a
      href={"/people/" <> @person.slug}
      role="option"
      class="flex items-center gap-3 px-2 py-2 rounded-md hover:bg-mist-50 no-underline"
    >
      <div class="w-10 h-10 rounded-full bg-mist-100 overflow-hidden shrink-0 grid place-items-center">
        <img
          :if={@person.profile_path}
          src={Movie.image_url(@person.profile_path, "w92")}
          alt=""
          loading="lazy"
          decoding="async"
          class="w-full h-full object-cover"
        />
        <span
          :if={!@person.profile_path}
          class="text-[10.5px] font-semibold text-mist-500 uppercase"
          aria-hidden="true"
        >
          {initials(@person.name)}
        </span>
      </div>
      <div class="flex-1 min-w-0">
        <div class="text-[13.5px] text-mist-950 truncate">{@person.name}</div>
        <div :if={@person.known_for_department} class="text-[11.5px] text-mist-500 truncate">
          {@person.known_for_department}
        </div>
      </div>
    </a>
    """
  end

  attr :list, :map, required: true

  defp list_row(assigns) do
    ~H"""
    <a
      href={"/lists/" <> @list.slug}
      role="option"
      class="flex items-center gap-3 px-2 py-2 rounded-md hover:bg-mist-50 no-underline"
    >
      <div
        class="w-10 h-10 rounded bg-mist-100 grid place-items-center shrink-0 text-lg"
        aria-hidden="true"
      >
        {@list.icon || "📜"}
      </div>
      <div class="flex-1 min-w-0">
        <div class="text-[13.5px] text-mist-950 truncate">{@list.name}</div>
        <div
          :if={@list.short_name && @list.short_name != @list.name}
          class="text-[11.5px] text-mist-500 truncate"
        >
          {@list.short_name}
        </div>
      </div>
    </a>
    """
  end

  attr :company, :map, required: true

  defp company_row(assigns) do
    ~H"""
    <div
      role="option"
      class="flex items-center gap-3 px-2 py-2 rounded-md text-mist-700 cursor-default"
      title="No detail page yet"
    >
      <div class="w-10 h-10 rounded bg-mist-100 overflow-hidden grid place-items-center shrink-0">
        <img
          :if={@company.logo_path}
          src={ProductionCompany.logo_url(@company.logo_path, "w92")}
          alt=""
          loading="lazy"
          decoding="async"
          class="max-w-full max-h-full object-contain"
        />
        <span :if={!@company.logo_path} class="text-mist-400 text-lg" aria-hidden="true">🏢</span>
      </div>
      <div class="flex-1 min-w-0">
        <div class="text-[13.5px] text-mist-950 truncate">{@company.name}</div>
        <div :if={@company.origin_country} class="text-[11.5px] text-mist-500 truncate">
          {@company.origin_country}
        </div>
      </div>
    </div>
    """
  end

  defp initials(nil), do: "?"

  defp initials(name) do
    name
    |> String.split(~r/\s+/, trim: true)
    |> Enum.take(2)
    |> Enum.map_join("", &String.first/1)
    |> String.upcase()
  end
end

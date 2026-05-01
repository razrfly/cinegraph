defmodule CinegraphWeb.MovieLive.IndexV2Drawer do
  @moduledoc """
  Drawer + modal templates for the V2 movies page (`/movies`).

  - `filters_drawer/1` — right-side panel with Lists, Festivals, Cast & Crew,
    Rating Quality, and Include Unreleased. Uses `phx-change="apply_filters"`
    so the existing `CinegraphWeb.SearchEventHandlers` macro can patch the URL
    on each toggle (live-update mode).
  - `scoring_modal/1` — port of v1's "How Cinegraph Scores Movies" modal,
    restyled with the `mist-*` palette.
  """
  use Phoenix.Component

  alias CinegraphWeb.NeutralV2Components

  attr :show, :boolean, default: false
  attr :filter_options, :map, required: true
  attr :selected_lists, :list, default: []
  attr :selected_festivals, :list, default: []
  attr :selected_people, :list, default: []
  attr :people_match, :string, default: nil
  attr :selected_decade, :string, default: nil
  attr :rating_preset, :string, default: nil
  attr :show_unreleased, :string, default: nil
  attr :active_filter_count, :integer, default: 0
  attr :scope, :map, default: %{}

  def filters_drawer(assigns) do
    ~H"""
    <NeutralV2Components.n_drawer
      id="filters-drawer"
      show={@show}
      title="Filters"
      on_close="hide_drawer"
    >
      <form phx-change="apply_filters" id="filters-drawer-form" class="space-y-8">
        <%!-- Hidden inputs ensure the form has *some* value for unchecked groups,
              otherwise apply_filters skips them entirely --%>
        <input :if={!list_scope?(@scope)} type="hidden" name="filters[lists][]" value="" />
        <input :if={!festival_scope?(@scope)} type="hidden" name="filters[festivals][]" value="" />

        <%!-- ─── Canonical Lists ─── --%>
        <section :if={!list_scope?(@scope)}>
          <h3 class="text-[11px] font-semibold tracking-[.08em] uppercase text-mist-500 mb-3">
            Canonical Lists
          </h3>
          <div class="space-y-2.5">
            <label
              :for={list <- @filter_options[:lists] || []}
              class="flex items-start gap-2.5 text-[13.5px] text-mist-900 cursor-pointer hover:text-mist-950 leading-snug"
            >
              <input
                type="checkbox"
                name="filters[lists][]"
                value={list.key}
                checked={list_selected?(list, @selected_lists)}
                class="mt-[2px] shrink-0 rounded border-mist-950/30 text-mist-950 focus:ring-mist-950 focus:ring-offset-0"
              />
              <span class="flex-1">{list.name}</span>
            </label>
            <p
              :if={@filter_options[:lists] in [nil, []]}
              class="text-[12px] text-mist-500 italic"
            >
              No lists configured.
            </p>
          </div>
        </section>

        <%!-- ─── Festivals / Awards ─── --%>
        <section :if={!festival_scope?(@scope)}>
          <h3 class="text-[11px] font-semibold tracking-[.08em] uppercase text-mist-500 mb-3">
            Festivals / Awards
          </h3>
          <div class="space-y-2.5 max-h-64 overflow-y-auto pr-1">
            <label
              :for={fest <- @filter_options[:festivals] || []}
              class="flex items-start gap-2.5 text-[13.5px] text-mist-900 cursor-pointer hover:text-mist-950 leading-snug"
            >
              <input
                type="checkbox"
                name="filters[festivals][]"
                value={to_string(fest.id)}
                checked={festival_selected?(fest, @selected_festivals)}
                class="mt-[2px] shrink-0 rounded border-mist-950/30 text-mist-950 focus:ring-mist-950 focus:ring-offset-0"
              />
              <span class="flex-1">{fest.name}</span>
            </label>
          </div>
        </section>
        <%!-- ─── Cast & Crew ─── --%>
        <section>
          <h3 class="text-[11px] font-semibold tracking-[.08em] uppercase text-mist-500 mb-3">
            Cast &amp; Crew
          </h3>
          <.live_component
            module={CinegraphWeb.Components.PersonAutocomplete}
            id="people-search-v2"
            field_name="filters[people_search]"
            selected_people={@selected_people}
            search_term=""
          />
          <div :if={length(@selected_people) >= 2} class="mt-3">
            <div class="grid grid-cols-2 gap-2" role="group" aria-label="People matching">
              <button
                type="button"
                phx-click="set_people_match"
                phx-value-match="any"
                aria-pressed={@people_match != "all"}
                class={[
                  "rounded-lg border px-3 py-2 text-[12.5px] font-semibold transition-colors",
                  if(@people_match == "all",
                    do: "bg-mist-50 border-mist-950/15 text-mist-700 hover:bg-mist-950/[0.025]",
                    else: "bg-mist-950 border-mist-950 text-mist-50"
                  )
                ]}
              >
                Any person
              </button>
              <button
                type="button"
                phx-click="set_people_match"
                phx-value-match="all"
                aria-pressed={@people_match == "all"}
                class={[
                  "rounded-lg border px-3 py-2 text-[12.5px] font-semibold transition-colors",
                  if(@people_match == "all",
                    do: "bg-mist-950 border-mist-950 text-mist-50",
                    else: "bg-mist-50 border-mist-950/15 text-mist-700 hover:bg-mist-950/[0.025]"
                  )
                ]}
              >
                All together
              </button>
            </div>
          </div>
        </section>
      </form>

      <%!-- ─── Decade (single-select pills) ─── --%>
      <section :if={(@filter_options[:decades] || []) != []}>
        <h3 class="text-[11px] font-semibold tracking-[.08em] uppercase text-mist-500 mb-3">
          Decade
        </h3>
        <div class="flex flex-wrap gap-2">
          <NeutralV2Components.n_chip_toggle
            :for={d <- @filter_options[:decades]}
            active={to_string(d.value) == to_string(@selected_decade || "")}
            phx-click="toggle_chip"
            phx-value-key="decade"
            phx-value-id={to_string(d.value)}
            phx-value-mode="single"
          >
            {d.label}
          </NeutralV2Components.n_chip_toggle>
        </div>
      </section>

      <%!-- ─── Rating Quality (segmented control) ─── --%>
      <section>
        <h3 class="text-[11px] font-semibold tracking-[.08em] uppercase text-mist-500 mb-3">
          Rating Quality
        </h3>
        <div class="grid grid-cols-2 sm:grid-cols-4 gap-2" role="group" aria-label="Rating Quality">
          <button
            :for={{value, label, sub} <- rating_preset_options()}
            type="button"
            phx-click="set_rating_preset"
            phx-value-id={value}
            aria-pressed={rating_preset_active?(@rating_preset, value)}
            class={[
              "flex flex-col items-center justify-center gap-[1px] rounded-lg border px-2 py-3 text-center transition-colors",
              if(rating_preset_active?(@rating_preset, value),
                do: "bg-mist-950 border-mist-950 text-mist-50",
                else: "bg-mist-50 border-mist-950/15 text-mist-900 hover:bg-mist-950/[0.025]"
              )
            ]}
          >
            <span class="text-[13px] font-semibold leading-tight">{label}</span>
            <span
              :if={sub}
              class={[
                "text-[10.5px] leading-tight",
                if(rating_preset_active?(@rating_preset, value),
                  do: "text-mist-300",
                  else: "text-mist-500"
                )
              ]}
            >
              {sub}
            </span>
          </button>
        </div>
      </section>

      <%!-- ─── Other ─── --%>
      <form phx-change="apply_filters">
        <section>
          <h3 class="text-[11px] font-semibold tracking-[.08em] uppercase text-mist-500 mb-3">
            Other
          </h3>
          <label class="flex items-center gap-2.5 text-[13.5px] text-mist-900 cursor-pointer">
            <input type="hidden" name="filters[show_unreleased]" value="" />
            <input
              type="checkbox"
              name="filters[show_unreleased]"
              value="true"
              checked={@show_unreleased == "true"}
              class="rounded border-mist-950/30 text-mist-950 focus:ring-mist-950 focus:ring-offset-0"
            />
            <span>Include unreleased films</span>
          </label>
        </section>
      </form>

      <:footer>
        <div class="flex items-center justify-between gap-2">
          <button
            type="button"
            phx-click="clear_filters"
            class="text-[13px] font-medium text-mist-700 underline decoration-mist-950/15 underline-offset-4 hover:text-mist-950"
          >
            Clear filters
          </button>
          <div class="flex items-center gap-3">
            <span :if={@active_filter_count > 0} class="text-[12px] text-mist-500 tabular-nums">
              {@active_filter_count} active
            </span>
            <button
              type="button"
              phx-click="hide_drawer"
              class="rounded-full bg-mist-950 text-mist-50 text-[13px] font-medium px-4 py-2 hover:bg-mist-800"
            >
              Done
            </button>
          </div>
        </div>
      </:footer>
    </NeutralV2Components.n_drawer>
    """
  end

  attr :show, :boolean, default: false

  def scoring_modal(assigns) do
    ~H"""
    <div :if={@show} class="fixed inset-0 z-50 flex items-center justify-center p-4">
      <div class="fixed inset-0 bg-mist-950/50"></div>
      <div
        class="relative bg-mist-50 rounded-2xl max-w-lg w-full p-6 shadow-2xl border border-mist-950/10"
        phx-click-away="hide_scoring_info"
        phx-window-keydown="hide_scoring_info"
        phx-key="Escape"
      >
        <div class="flex justify-between items-start mb-5">
          <h2 class="font-display italic text-[24px] text-mist-950">
            How Cinegraph Scores Movies
          </h2>
          <button
            phx-click="hide_scoring_info"
            class="text-mist-500 hover:text-mist-950 text-[18px] leading-none"
            aria-label="Close"
          >
            ✕
          </button>
        </div>
        <div class="space-y-4">
          <div :for={{emoji, name, tagline, desc} <- scoring_lenses()} class="flex gap-3">
            <div class="text-2xl flex-shrink-0">{emoji}</div>
            <div>
              <div class="font-semibold text-mist-950 text-[14px]">{name}</div>
              <div class="text-[11px] text-mist-500 italic mb-0.5">"{tagline}"</div>
              <div class="text-[13px] text-mist-700">{desc}</div>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp rating_preset_options do
    [
      {"", "Any", "rating"},
      {"highly_rated", "7.5+", "Acclaimed"},
      {"well_reviewed", "6.0+", "Solid"},
      {"critically_acclaimed", "Top tier", "Critics' picks"}
    ]
  end

  defp rating_preset_active?(nil, ""), do: true
  defp rating_preset_active?("", ""), do: true
  defp rating_preset_active?(current, value), do: to_string(current) == value

  defp list_selected?(list, selected) do
    list.key in selected or Map.get(list, :slug) in selected
  end

  defp festival_selected?(festival, selected) do
    to_string(festival.id) in selected or Map.get(festival, :slug) in selected
  end

  defp scoring_lenses do
    [
      {"🔥", "The Mob", "Millions voted.", "IMDb, TMDb, and Rotten Tomatoes audience scores."},
      {"🎭", "The Critics", "The anointed few.",
       "Metacritic Metascore + Rotten Tomatoes Tomatometer."},
      {"🏆", "The Insiders", "Hollywood pats itself.",
       "Festival wins, Oscar nominations, major awards."},
      {"⏳", "The Time Machine", "What survives the hype.",
       "Criterion, 1001 Movies, Sight & Sound lists."},
      {"🎬", "The Auteurs", "Great films start with great people.",
       "Director and cast quality scores."},
      {"💵", "The Box Office", "Follow the money.", "Global revenue relative to budget."}
    ]
  end

  defp list_scope?(%{kind: :list}), do: true
  defp list_scope?(%{kind: "list"}), do: true
  defp list_scope?(_), do: false

  defp festival_scope?(%{kind: :festival}), do: true
  defp festival_scope?(%{kind: "festival"}), do: true
  defp festival_scope?(_), do: false
end

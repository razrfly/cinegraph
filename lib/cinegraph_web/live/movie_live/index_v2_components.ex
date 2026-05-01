defmodule CinegraphWeb.MovieLive.IndexV2Components do
  @moduledoc """
  Render-only facade for the V2 movie discovery page.

  Focused component groups live under `IndexV2Components.*`; this module keeps
  the stable API used by the LiveView and component tests.
  """
  use Phoenix.Component

  alias CinegraphWeb.MovieLive.IndexV2Components.ActiveChips
  alias CinegraphWeb.MovieLive.IndexV2Components.CardHelpers
  alias CinegraphWeb.MovieLive.IndexV2Components.Filters

  attr :total_count, :integer, default: nil

  def hero(assigns) do
    ~H"""
    <section class="mb-8 lg:mb-12">
      <h1 class="font-display italic text-[44px] sm:text-[56px] lg:text-[72px] tracking-[-.02em] text-balance text-mist-950 leading-[1.02]">
        Movies.
      </h1>
      <p class="text-[15px] text-mist-700 mt-2 max-w-2xl">
        {format_count(@total_count)} films across canonical lists, festivals, and critical canon.
      </p>
      <div class="flex items-center gap-3 mt-1.5 text-[14px] text-mist-700">
        <a
          href="/movies/discover"
          class="underline decoration-mist-950/15 underline-offset-4 hover:text-mist-950"
        >
          Tunable scoring →
        </a>
        <span class="text-mist-500" aria-hidden="true">·</span>
        <button
          type="button"
          phx-click="show_scoring_info"
          class="underline decoration-mist-950/15 underline-offset-4 hover:text-mist-950 bg-transparent border-0 p-0 cursor-pointer font-[inherit] text-[14px] text-mist-700"
        >
          How we score?
        </button>
      </div>
    </section>
    """
  end

  attr :search_term, :string, default: ""
  attr :sort_options, :list, required: true
  attr :sort_criteria, :string, default: "release_date"
  attr :sort_direction, :atom, default: :desc
  attr :sort_is_preset, :boolean, default: false
  attr :filter_options, :map, required: true
  attr :params, :map, required: true
  attr :active_filter_count, :integer, default: 0

  def filters(assigns), do: Filters.filters(assigns)

  attr :params, :map, required: true
  attr :filter_options, :map, required: true
  attr :sort_options, :list, required: true

  def active_filters(assigns), do: ActiveChips.active_filters(assigns)

  attr :movies, :list, required: true
  attr :active_lens_key, :any, default: nil

  def results(assigns), do: CardHelpers.results(assigns)

  attr :meta, :any, required: true

  def pagination(assigns) do
    ~H"""
    <nav
      :if={@meta && @meta.total_pages && @meta.total_pages > 1}
      class="flex items-center justify-between gap-4 pt-6 border-t border-mist-950/10 text-[13px] text-mist-700"
    >
      <button
        type="button"
        phx-click="page"
        phx-value-page={max(1, (@meta.current_page || 1) - 1)}
        disabled={(@meta.current_page || 1) <= 1}
        class="inline-flex items-center gap-2 rounded-full border border-mist-950/15 bg-mist-50 px-4 py-2 font-medium text-mist-950 hover:bg-mist-950/[0.025] disabled:opacity-40 disabled:cursor-not-allowed"
      >
        ← Previous
      </button>

      <div class="text-[12px] tabular-nums">
        Page <b class="text-mist-950 font-semibold">{@meta.current_page}</b>
        of <b class="text-mist-950 font-semibold">{@meta.total_pages}</b>
        <span class="text-mist-500">
          · {format_count(@meta.total_count)} films
        </span>
      </div>

      <button
        type="button"
        phx-click="page"
        phx-value-page={min(@meta.total_pages, (@meta.current_page || 1) + 1)}
        disabled={(@meta.current_page || 1) >= @meta.total_pages}
        class="inline-flex items-center gap-2 rounded-full border border-mist-950/15 bg-mist-50 px-4 py-2 font-medium text-mist-950 hover:bg-mist-950/[0.025] disabled:opacity-40 disabled:cursor-not-allowed"
      >
        Next →
      </button>
    </nav>
    """
  end

  defdelegate active_filter_count(params), to: Filters
  defdelegate list_param(params, key), to: Filters
  defdelegate selected_people_ids(params), to: Filters

  defp format_count(nil), do: "—"

  defp format_count(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end
end

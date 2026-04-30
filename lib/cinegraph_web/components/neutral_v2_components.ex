defmodule CinegraphWeb.NeutralV2Components do
  @moduledoc """
  Cinegraph Neutral design system — V2, on Oatmeal foundation.

  Drop-in mirror of `CinegraphWeb.NeutralComponents` with the same prop
  signatures and DOM logic, but the foundation tokens are swapped from the
  bespoke `cg-*` palette to the Oatmeal kit's `mist-*` palette + Instrument
  Serif italic display + Inter body. Resolves against the existing
  `tailwind.oatmeal.config.js` build (`priv/static/assets/oatmeal.css`) — no
  new build profile needed.

  Same component prefix `n_` so a v2 template can be made by find-and-
  replace `<NeutralComponents.n_*>` → `<NeutralV2Components.n_*>`.
  """
  use Phoenix.Component

  alias CinegraphWeb.NeutralDesign.PosterSvg

  # ──────────────────────────────────────────────────────────────────
  # PRIMITIVES
  # ──────────────────────────────────────────────────────────────────

  @doc "Pill — 6 tones (neutral/blue/green/amber/red/ink) × 3 sizes (xs/sm/md)."
  attr :tone, :string, default: "neutral"
  attr :size, :string, default: "sm"
  attr :class, :string, default: ""
  slot :inner_block, required: true

  def n_pill(assigns) do
    ~H"""
    <span class={[
      "inline-flex items-center gap-[5px] rounded-md font-medium leading-tight border",
      pill_size(@size),
      pill_tone(@tone),
      @class
    ]}>
      {render_slot(@inner_block)}
    </span>
    """
  end

  defp pill_size("xs"), do: "px-[7px] py-[2px] text-[10.5px]"
  defp pill_size("md"), do: "px-3 py-[5px] text-[13px]"
  defp pill_size(_), do: "px-[9px] py-[3px] text-[11.5px]"

  defp pill_tone("blue"), do: "bg-blue-50 text-blue-800 border-transparent"
  defp pill_tone("green"), do: "bg-emerald-50 text-emerald-800 border-transparent"
  defp pill_tone("amber"), do: "bg-amber-50 text-amber-800 border-transparent"
  defp pill_tone("red"), do: "bg-rose-50 text-rose-800 border-transparent"
  defp pill_tone("ink"), do: "bg-mist-950 text-mist-50 border-transparent"
  defp pill_tone(_), do: "bg-mist-950/[0.025] text-mist-900 border-mist-950/10"

  @doc "Delta indicator — ▲/▼ with green/red, tabular numerals."
  attr :value, :integer, required: true
  attr :suffix, :string, default: ""

  def n_delta(assigns) do
    ~H"""
    <%= if @value == 0 do %>
      <span class="text-mist-500 text-[11px] tabular-nums">—</span>
    <% else %>
      <span class={[
        "inline-flex items-center gap-[3px] text-[11px] font-semibold tabular-nums",
        if(@value > 0, do: "text-emerald-700", else: "text-rose-700")
      ]}>
        <span class="text-[9px]">{if @value > 0, do: "▲", else: "▼"}</span>
        {abs(@value)}{@suffix}
      </span>
    <% end %>
    """
  end

  @doc "Eyebrow — uppercase tracked label."
  attr :class, :string, default: ""
  slot :inner_block, required: true

  def n_eyebrow(assigns) do
    ~H"""
    <div class={["text-[11px] font-semibold tracking-[.1em] uppercase text-mist-500", @class]}>
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc """
  Section header — title + subtitle + right-aligned action slot.

  V2 difference: title is `font-display italic` (Instrument Serif italic)
  for the editorial Oatmeal voice.
  """
  attr :title, :string, required: true
  attr :subtitle, :string, default: nil
  attr :kicker, :string, default: nil
  attr :class, :string, default: ""
  slot :action

  def n_section_header(assigns) do
    ~H"""
    <div class={["flex items-end justify-between gap-6 mb-[18px]", @class]}>
      <div>
        <.n_eyebrow :if={@kicker} class="mb-[6px]">{@kicker}</.n_eyebrow>
        <h2 class="font-display italic text-[28px] tracking-[-.01em] text-mist-950 leading-[1.1]">
          {@title}
        </h2>
        <div :if={@subtitle} class="text-[13.5px] text-mist-700 mt-2">
          {@subtitle}
        </div>
      </div>
      <div :if={@action != []} class="shrink-0">
        {render_slot(@action)}
      </div>
    </div>
    """
  end

  @doc "Link action — \"See all →\" border-bottom link."
  attr :href, :string, default: "#"
  attr :icon, :string, default: "→"
  slot :inner_block, required: true

  def n_link_action(assigns) do
    ~H"""
    <a
      href={@href}
      class="inline-flex items-center gap-[6px] text-[12.5px] font-semibold text-mist-900 no-underline border-b border-mist-950/15 pb-px"
    >
      {render_slot(@inner_block)}<span class="text-[11px] opacity-70">{@icon}</span>
    </a>
    """
  end

  @doc "Button — primary (ink bg) / secondary (white) / ghost (transparent), 3 sizes."
  attr :variant, :string, default: "secondary"
  attr :size, :string, default: "md"
  attr :icon, :string, default: nil
  attr :class, :string, default: ""
  attr :rest, :global, include: ~w(href type disabled)
  slot :inner_block, required: true

  def n_btn(assigns) do
    ~H"""
    <button
      class={[
        "inline-flex items-center gap-[7px] font-semibold border rounded-[7px] cursor-pointer tracking-[-.005em] transition-colors",
        btn_size(@size),
        btn_variant(@variant),
        @class
      ]}
      {@rest}
    >
      <span :if={@icon} class="leading-none">{@icon}</span>
      {render_slot(@inner_block)}
    </button>
    """
  end

  defp btn_size("sm"), do: "px-[10px] py-[5px] h-7 text-[12px]"
  defp btn_size("lg"), do: "px-[18px] py-[11px] h-[42px] text-[13.5px]"
  defp btn_size(_), do: "px-[14px] py-2 h-9 text-[13px]"

  defp btn_variant("primary"),
    do: "bg-mist-950 text-mist-50 border-mist-950 hover:bg-mist-900"

  defp btn_variant("ghost"),
    do: "bg-transparent text-mist-900 border-transparent hover:bg-mist-950/[0.05]"

  defp btn_variant(_),
    do: "bg-mist-50 text-mist-950 border-mist-950/15 hover:bg-mist-950/[0.025]"

  @doc "Brand mark — ink rounded square + 4-node graph SVG + Cinegraph wordmark."
  attr :size, :integer, default: 18

  def n_brand(assigns) do
    ~H"""
    <div class="inline-flex items-center gap-2">
      <svg
        width={@size}
        height={@size}
        viewBox="0 0 24 24"
        class="shrink-0"
        aria-hidden="true"
      >
        <rect x="2" y="2" width="20" height="20" rx="4" fill="#16140f" />
        <path
          d="M7 12 L11 8 L15 14 L17 11"
          fill="none"
          stroke="#fff"
          stroke-width="1.6"
          stroke-linecap="round"
          stroke-linejoin="round"
        />
        <circle cx="7" cy="12" r="1.4" fill="#fff" />
        <circle cx="11" cy="8" r="1.4" fill="#fff" />
        <circle cx="15" cy="14" r="1.4" fill="#fff" />
        <circle cx="17" cy="11" r="1.4" fill="#fff" />
      </svg>
      <span
        class="font-semibold tracking-[-.018em] text-mist-950"
        style={"font-size: #{@size - 2}px"}
      >
        Cinegraph
      </span>
    </div>
    """
  end

  @doc "Tabs — segmented switch on subtle surface."
  attr :tabs, :list, required: true
  attr :value, :string, required: true

  def n_tabs(assigns) do
    ~H"""
    <div class="inline-flex p-[3px] bg-mist-950/[0.025] border border-mist-950/10 rounded-lg gap-[2px]">
      <button
        :for={t <- @tabs}
        type="button"
        class={[
          "px-3 py-[6px] text-[12.5px] border-0 rounded-[6px] cursor-pointer tracking-[-.005em]",
          if(t == @value,
            do: "font-semibold text-mist-950 bg-mist-50 shadow-[0_1px_2px_rgba(20,18,15,.06)]",
            else: "font-medium text-mist-700 bg-transparent"
          )
        ]}
      >
        {t}
      </button>
    </div>
    """
  end

  # ──────────────────────────────────────────────────────────────────
  # NAV / SEARCH
  # ──────────────────────────────────────────────────────────────────

  @doc """
  Top navigation — sticky, blurred, brand + items + search + actions.

  V2 difference: uses Oatmeal's responsive container rhythm
  (`max-w-2xl` → `max-w-3xl` → `max-w-7xl`) so it works on mobile
  out of the box.
  """
  attr :active, :string, default: "Movies"
  attr :mobile, :boolean, default: false

  slot :search,
    doc:
      "Optional override for the desktop search slot. Falls back to the static n_search_input stub."

  def n_top_nav(assigns) do
    items = [
      %{id: "Movies", badge: nil},
      %{id: "TV", badge: nil},
      %{id: "People", badge: nil},
      %{id: "Lists", badge: nil},
      %{id: "Trends", badge: nil},
      %{id: "Data", badge: "BETA"}
    ]

    assigns = assign(assigns, :items, items)

    ~H"""
    <header class="sticky top-0 z-[5] bg-mist-100/[0.92] dark:bg-mist-950/[0.92] backdrop-blur-md border-b border-mist-950/10 dark:border-white/10">
      <div class="mx-auto w-full max-w-2xl px-6 md:max-w-3xl lg:max-w-7xl lg:px-10 flex items-center gap-4 py-[14px]">
        <.n_brand size={19} />
        <nav class="flex gap-[2px] items-center max-md:hidden">
          <a
            :for={item <- @items}
            href="#"
            class={[
              "inline-flex items-center gap-[6px] px-3 py-[7px] rounded-md text-[13.5px] no-underline tracking-[-.005em]",
              if(item.id == @active,
                do:
                  "font-semibold text-mist-950 dark:text-white bg-mist-950/[0.025] dark:bg-white/10",
                else: "font-medium text-mist-700 dark:text-mist-400 bg-transparent"
              )
            ]}
          >
            {item.id}
            <span
              :if={item.badge}
              class="text-[9px] font-bold px-[5px] py-[2px] bg-mist-950 text-mist-50 rounded-[3px] tracking-[.05em]"
            >
              {item.badge}
            </span>
          </a>
        </nav>
        <div class="flex-1 max-w-[420px] ml-auto max-md:hidden">
          <%= if @search != [] do %>
            {render_slot(@search)}
          <% else %>
            <.n_search_input compact />
          <% end %>
        </div>
        <div class="flex items-center gap-2 ml-auto md:ml-0">
          <button
            id="theme-toggle"
            type="button"
            phx-hook="ThemeToggle"
            class="w-[34px] h-[34px] rounded-[7px] border border-mist-950/10 dark:border-white/10 bg-mist-50 dark:bg-white/5 hover:bg-mist-950/[0.04] dark:hover:bg-white/10 grid place-items-center cursor-pointer max-md:hidden"
            aria-label="Toggle dark mode"
            aria-pressed="false"
          >
            <svg
              width="14"
              height="14"
              viewBox="0 0 16 16"
              fill="none"
              class="block dark:hidden text-mist-900 dark:text-white"
              aria-hidden="true"
            >
              <path
                d="M8 1.5 V3 M8 13 V14.5 M3.5 3.5 L4.5 4.5 M11.5 11.5 L12.5 12.5 M1.5 8 H3 M13 8 H14.5 M3.5 12.5 L4.5 11.5 M11.5 4.5 L12.5 3.5"
                stroke="currentColor"
                stroke-width="1.4"
                stroke-linecap="round"
              />
              <circle
                cx="8"
                cy="8"
                r="2.5"
                stroke="currentColor"
                stroke-width="1.4"
              />
            </svg>
            <svg
              width="14"
              height="14"
              viewBox="0 0 16 16"
              fill="none"
              class="hidden dark:block text-mist-900 dark:text-white"
              aria-hidden="true"
            >
              <path
                d="M13.5 9.5 A6 6 0 0 1 6.5 2.5 A6 6 0 1 0 13.5 9.5 Z"
                fill="currentColor"
              />
            </svg>
          </button>
          <button
            type="button"
            class="w-[34px] h-[34px] rounded-[7px] border border-mist-950/10 dark:border-white/10 bg-mist-50 dark:bg-white/5 grid place-items-center cursor-pointer md:hidden"
            aria-label="Search"
          >
            <svg width="14" height="14" viewBox="0 0 16 16" fill="none">
              <circle
                cx="7"
                cy="7"
                r="5"
                stroke="currentColor"
                class="text-mist-900 dark:text-white"
                stroke-width="1.4"
              />
              <path
                d="M11 11 L14 14"
                stroke="currentColor"
                class="text-mist-900 dark:text-white"
                stroke-width="1.4"
                stroke-linecap="round"
              />
            </svg>
          </button>
          <button
            type="button"
            class="h-[34px] px-3 rounded-[7px] border border-mist-950/10 dark:border-white/10 bg-mist-50 dark:bg-white/5 text-[12.5px] font-semibold text-mist-950 dark:text-white cursor-pointer max-sm:hidden"
          >
            Sign in
          </button>
          <a
            href="#"
            class="inline-flex shrink-0 items-center justify-center gap-1 rounded-full bg-mist-950 dark:bg-white px-3 py-1 text-sm/7 font-medium text-mist-100 dark:text-mist-950 hover:bg-mist-800 dark:hover:bg-mist-200"
          >
            Get started
          </a>
        </div>
      </div>
    </header>
    """
  end

  @doc "Search input — compact / focused / mobile variants."
  attr :compact, :boolean, default: false
  attr :focused, :boolean, default: false
  attr :mobile, :boolean, default: false

  def n_search_input(assigns) do
    placeholder =
      if assigns[:mobile],
        do: "Search films, people, lists…",
        else: "Search films, people, lists, companies…"

    assigns = assign(assigns, :placeholder, placeholder)

    ~H"""
    <div class="relative">
      <div class={[
        "relative flex items-center bg-mist-50 rounded-lg transition-colors",
        if(@compact, do: "h-9 px-3", else: "h-11 px-[14px]"),
        if(@focused,
          do: "border border-mist-950 shadow-[0_0_0_3px_rgba(0,0,0,.04)]",
          else: "border border-mist-950/15"
        )
      ]}>
        <svg
          width={if @compact, do: "13", else: "15"}
          height={if @compact, do: "13", else: "15"}
          viewBox="0 0 16 16"
          fill="none"
          class="shrink-0 text-mist-500"
        >
          <circle cx="7" cy="7" r="5" stroke="currentColor" stroke-width="1.4" />
          <path d="M11 11 L14 14" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" />
        </svg>
        <input
          placeholder={@placeholder}
          class={[
            "flex-1 ml-[9px] text-mist-950 bg-transparent border-0 outline-none min-w-0 font-[inherit]",
            if(@compact, do: "text-[13px]", else: "text-[14.5px]")
          ]}
        />
        <div :if={!@compact} class="flex items-center gap-[6px] shrink-0">
          <kbd class="font-mono text-[10.5px] font-semibold px-[6px] py-[3px] bg-mist-950/[0.025] border border-mist-950/10 rounded-[4px] text-mist-700">
            ⌘K
          </kbd>
        </div>
      </div>
    </div>
    """
  end

  @doc "Search hero — focused search + type tabs + genre chips + filter pills."
  attr :genres, :list, required: true

  def n_search_hero(assigns) do
    tabs = ["Films", "TV", "People", "Companies", "Lists", "Genres", "Years"]
    assigns = assign(assigns, :tabs, tabs)

    ~H"""
    <section class="pb-6">
      <.n_search_input focused />
      <div class="flex items-center mt-[14px] border-b border-mist-950/10 overflow-x-auto">
        <button
          :for={t <- @tabs}
          type="button"
          class={[
            "py-[9px] px-[14px] text-[13px] bg-transparent border-0 cursor-pointer -mb-px tracking-[-.005em] whitespace-nowrap",
            if(t == "Films",
              do: "font-semibold text-mist-950 border-b-2 border-mist-950",
              else: "font-medium text-mist-700 border-b-2 border-transparent"
            )
          ]}
        >
          {t}<span
            :if={t == "Films"}
            class="ml-[6px] text-[10.5px] font-medium text-mist-500 tabular-nums"
          >16,420</span>
          <span
            :if={t == "People"}
            class="ml-[6px] text-[10.5px] font-medium text-mist-500 tabular-nums"
          >
            48,923
          </span>
          <span
            :if={t == "Lists"}
            class="ml-[6px] text-[10.5px] font-medium text-mist-500 tabular-nums"
          >
            312
          </span>
        </button>
      </div>
      <div class="flex items-center gap-[6px] mt-[14px] overflow-x-auto pb-[2px]">
        <span class="text-[11px] font-semibold text-mist-500 tracking-[.06em] uppercase shrink-0 mr-1">
          GENRE
        </span>
        <button
          :for={g <- @genres}
          type="button"
          class={[
            "px-[11px] py-[5px] text-[12px] rounded-full cursor-pointer whitespace-nowrap shrink-0",
            if(g == "All",
              do: "font-semibold text-mist-50 bg-mist-950 border border-mist-950",
              else: "font-medium text-mist-900 bg-mist-50 border border-mist-950/10"
            )
          ]}
        >
          {g}
        </button>
        <span class="w-px h-[18px] bg-mist-950/10 mx-[6px] shrink-0"></span>
        <.n_pill tone="neutral" size="sm" class="shrink-0">1990–2025 ⌃</.n_pill>
        <.n_pill tone="neutral" size="sm" class="shrink-0">Any rating ⌃</.n_pill>
        <.n_pill tone="neutral" size="sm" class="shrink-0">+ Add filter</.n_pill>
      </div>
    </section>
    """
  end

  # ──────────────────────────────────────────────────────────────────
  # MEDIA CARDS
  # ──────────────────────────────────────────────────────────────────

  @doc "Film card — 2:3 poster + corner badges + title/year + director/delta meta."
  attr :film, :map, required: true
  attr :rank, :integer, default: nil
  attr :show_score, :boolean, default: true
  attr :compact, :boolean, default: false

  def n_film_card(assigns) do
    poster = assigns.film[:poster_url] || maybe_generated_poster(assigns.film)
    score = card_score(assigns.film)
    href = assigns.film[:href] || "#"

    assigns =
      assigns
      |> assign(:poster, poster)
      |> assign(:score, score)
      |> assign(:href, href)

    ~H"""
    <a href={@href} class="block no-underline text-inherit">
      <div class="relative aspect-[2/3] rounded-[6px] overflow-hidden bg-mist-100 border border-mist-950/10">
        <img
          :if={@poster}
          src={@poster}
          alt={@film.title}
          class="w-full h-full object-cover block"
        />
        <div
          :if={!@poster}
          class="w-full h-full grid place-items-center bg-gradient-to-br from-mist-200 to-mist-300 text-mist-700 font-display italic text-[14px] text-center px-3"
        >
          {@film.title}
        </div>
        <div
          :if={@rank}
          class="absolute top-0 left-0 px-[10px] pl-2 py-[5px] bg-black/[0.78] text-white text-[11px] font-bold tracking-[.04em] rounded-br-[6px] tabular-nums"
        >
          #{@rank}
        </div>
        <div
          :if={@show_score && @score}
          class="absolute top-2 right-2 px-[7px] py-[3px] bg-white/[0.92] text-mist-950 text-[11px] font-bold rounded-[4px] tabular-nums tracking-[-.01em]"
        >
          {@score}
        </div>
      </div>
      <div class="pt-[10px]">
        <div class="flex items-baseline justify-between gap-2">
          <div class="text-[13.5px] font-semibold text-mist-950 tracking-[-.005em] leading-[1.25] whitespace-nowrap overflow-hidden text-ellipsis flex-1 min-w-0">
            {@film.title}
          </div>
          <div class="text-[12px] text-mist-500 tabular-nums shrink-0">{@film.year}</div>
        </div>
        <div
          :if={!@compact && (@film[:dir] || Map.has_key?(@film, :delta))}
          class="flex items-center gap-2 mt-[5px] text-[11.5px] text-mist-700"
        >
          <span class="whitespace-nowrap overflow-hidden text-ellipsis flex-1 min-w-0">
            {@film[:dir]}
          </span>
          <.n_delta :if={Map.has_key?(@film, :delta)} value={@film.delta} />
        </div>
        <div
          :if={!@compact && @film[:reason]}
          class="mt-[5px] pl-2 border-l-2 border-mist-950/30 italic text-[11px] text-mist-500 truncate"
        >
          {@film.reason}
        </div>
      </div>
    </a>
    """
  end

  # Generate an SVG placeholder ONLY when the film map has the rich mock-data
  # shape (id + title + year + dir + genre). Real Movie structs from the DB
  # don't have :dir/:genre, so we skip the generator and render a blank tile.
  defp maybe_generated_poster(%{title: title, dir: dir, year: year, genre: genre, id: id})
       when is_binary(title) and is_binary(dir) do
    PosterSvg.poster(%{id: id, title: title, dir: dir, year: year, genre: genre})
  end

  defp maybe_generated_poster(_), do: nil

  # Compute card score from explicit :score, else avg of the 4 dimension fields.
  defp card_score(%{score: nil}), do: nil
  defp card_score(%{score: s}), do: s

  defp card_score(%{pop: pop, crit: crit, cult: cult, ppl: ppl})
       when is_number(pop) and is_number(crit) and is_number(cult) and is_number(ppl),
       do: round((pop + crit + cult + ppl) / 4)

  defp card_score(_), do: nil

  @doc "Person card — rank + avatar + name + role + delta% + film count."
  attr :person, :map, required: true
  attr :rank, :integer, default: nil

  def n_person_card(assigns) do
    avatar = PosterSvg.avatar(assigns.person)
    assigns = assign(assigns, :avatar, avatar)

    ~H"""
    <a
      href="#"
      class="flex gap-3 items-center px-[14px] py-3 no-underline text-inherit rounded-lg transition-colors hover:bg-mist-950/[0.025] relative"
    >
      <div
        :if={@rank}
        class="w-[18px] text-[11px] text-mist-500 tabular-nums font-semibold text-right shrink-0"
      >
        {@rank}
      </div>
      <img
        src={@avatar}
        alt=""
        class="w-[38px] h-[38px] rounded-full shrink-0 border border-mist-950/10"
      />
      <div class="flex-1 min-w-0">
        <div class="flex items-center gap-[7px]">
          <div class="text-[13.5px] font-semibold text-mist-950 tracking-[-.005em] whitespace-nowrap overflow-hidden text-ellipsis">
            {@person.name}
          </div>
          <span
            :if={@person.trending}
            class="w-[5px] h-[5px] rounded-full bg-emerald-500 shrink-0"
          >
          </span>
        </div>
        <div class="text-[11.5px] text-mist-700 mt-[2px] whitespace-nowrap overflow-hidden text-ellipsis">
          {@person.role}{if known = List.first(@person.known_for || []), do: " · #{known}", else: ""}
        </div>
      </div>
      <div class="text-right shrink-0">
        <.n_delta value={@person.delta_pct} suffix="%" />
        <div class="text-[10.5px] text-mist-500 tabular-nums mt-[2px]">{@person.films} films</div>
      </div>
    </a>
    """
  end

  @doc "List card — 4-poster strip + name + curator + count pill + updated."
  attr :list, :map, required: true
  attr :films, :list, required: true

  def n_list_card(assigns) do
    posters = assigns.films |> Enum.take(4) |> Enum.map(&{&1.id, PosterSvg.poster(&1)})
    assigns = assign(assigns, :posters, posters)

    ~H"""
    <a
      href="#"
      class="block no-underline text-inherit border border-mist-950/10 rounded-lg overflow-hidden bg-mist-50 transition-shadow hover:shadow-[0_4px_14px_rgba(20,18,15,.06)] relative"
    >
      <div class="grid grid-cols-4 gap-px bg-mist-950/10 aspect-[8/3]">
        <img
          :for={{id, src} <- @posters}
          src={src}
          alt=""
          class="w-full h-full object-cover block"
          data-id={id}
        />
      </div>
      <div class="px-4 pt-[14px] pb-4">
        <div class="flex items-start justify-between gap-[10px]">
          <div class="flex-1 min-w-0">
            <div class="text-[14px] font-semibold text-mist-950 leading-[1.3] tracking-[-.008em]">
              {@list.name}
            </div>
            <div class="text-[11.5px] text-mist-700 mt-[3px]">{@list.curator}</div>
          </div>
          <.n_pill tone={@list.accent} size="xs">{@list.count}</.n_pill>
        </div>
        <div class="flex items-center justify-between mt-[11px] text-[11px] text-mist-500">
          <span>Updated {@list.updated}</span>
          <span class="font-semibold text-mist-900">View →</span>
        </div>
      </div>
    </a>
    """
  end

  # ──────────────────────────────────────────────────────────────────
  # DATA CALLOUTS
  # ──────────────────────────────────────────────────────────────────

  @doc "Insight tile — uppercase label + big value + sub + sparkline + delta."
  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :delta, :integer, required: true
  attr :sub, :string, required: true
  attr :spark_seed, :integer, default: 1

  def n_insight_tile(assigns) do
    {points, w, h} = sparkline(assigns.spark_seed)
    path = sparkline_path(points, w, h)
    fmt_val = format_value(assigns.value)

    assigns =
      assigns
      |> assign(:path, path)
      |> assign(:fmt_val, fmt_val)
      |> assign(:w, w)
      |> assign(:h, h)

    ~H"""
    <div class="px-4 py-[14px] bg-mist-50 border border-mist-950/10 rounded-lg">
      <div class="text-[11px] font-semibold text-mist-500 tracking-[.04em] uppercase">
        {@label}
      </div>
      <div class="flex items-end justify-between gap-[10px] mt-[6px]">
        <div>
          <div class="text-[26px] font-semibold text-mist-950 tracking-[-.02em] tabular-nums leading-[1.05]">
            {@fmt_val}
          </div>
          <div class="text-[11.5px] text-mist-700 mt-[3px]">{@sub}</div>
        </div>
        <div class="text-right shrink-0">
          <svg width={@w} height={@h} class="block text-mist-700">
            <path
              d={@path}
              fill="none"
              stroke="currentColor"
              stroke-width="1.3"
              stroke-linecap="round"
              stroke-linejoin="round"
            />
          </svg>
          <div class="mt-1"><.n_delta value={@delta} /></div>
        </div>
      </div>
    </div>
    """
  end

  defp sparkline(seed) do
    w = 100
    h = 28
    init_v = 30 + rem(seed * 7, 30)

    {points, _} =
      Enum.reduce(0..13, {[], init_v}, fn i, {acc, v} ->
        v = v + (rem(seed * i + 7, 11) - 4)
        v = v |> max(10) |> min(70)
        {acc ++ [v], v}
      end)

    {points, w, h}
  end

  defp sparkline_path(points, w, h) do
    n = length(points)

    points
    |> Enum.with_index()
    |> Enum.map_join(" ", fn {p, i} ->
      x = i / (n - 1) * w
      y = h - p / 80 * h

      cmd = if i == 0, do: "M", else: "L"
      "#{cmd}#{Float.round(x, 2)} #{Float.round(y, 2)}"
    end)
  end

  defp format_value(v) when is_float(v), do: :erlang.float_to_binary(v, decimals: 1)

  defp format_value(v) when is_integer(v) do
    v
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  defp format_value(v), do: to_string(v)

  @doc "Update row — type pill + text + ago timestamp."
  attr :update, :map, required: true

  def n_update_row(assigns) do
    {tone, label} = update_meta(assigns.update.type)
    assigns = assigns |> assign(:tone, tone) |> assign(:label, label)

    ~H"""
    <div class="grid grid-cols-[72px_1fr_auto] gap-[14px] py-3 border-b border-mist-950/10 items-baseline">
      <.n_pill tone={@tone} size="xs" class="justify-self-start">{@label}</.n_pill>
      <div class="text-[13.5px] text-mist-900 leading-[1.45] tracking-[-.003em]">
        {@update.text}
      </div>
      <div class="text-[11.5px] text-mist-500 tabular-nums whitespace-nowrap">{@update.ago} ago</div>
    </div>
    """
  end

  defp update_meta(:awards), do: {"amber", "AWARDS"}
  defp update_meta(:data), do: {"blue", "DATA"}
  defp update_meta(:release), do: {"green", "RELEASE"}
  defp update_meta(:collab), do: {"neutral", "COLLAB"}
  defp update_meta(:list), do: {"red", "LIST"}
  defp update_meta(other), do: {"neutral", other |> to_string() |> String.upcase()}

  @doc "Graph preview — dotted-grid background + nodes (films=rect, people=circle) + legend."
  attr :graph, :map, required: true
  attr :width, :integer, default: 520
  attr :height, :integer, default: 300

  def n_graph_preview(assigns) do
    %{nodes: nodes, edges: edges} = assigns.graph
    by_id = Map.new(nodes, fn n -> {n.id, n} end)

    edges_xy =
      edges
      |> Enum.map(fn {a, b} -> {by_id[a], by_id[b]} end)
      |> Enum.filter(fn {na, nb} -> na && nb end)
      |> Enum.map(fn {na, nb} ->
        {na.x * assigns.width, na.y * assigns.height, nb.x * assigns.width, nb.y * assigns.height}
      end)

    nodes_xy =
      Enum.map(nodes, fn n ->
        Map.merge(n, %{px: n.x * assigns.width, py: n.y * assigns.height})
      end)

    assigns =
      assigns
      |> assign(:edges_xy, edges_xy)
      |> assign(:nodes_xy, nodes_xy)

    ~H"""
    <div
      class="relative w-full bg-mist-950/[0.025] border border-mist-950/10 rounded-lg overflow-hidden"
      style={"height: #{@height}px"}
    >
      <svg
        width="100%"
        height="100%"
        class="absolute inset-0"
        preserveAspectRatio="none"
        viewBox={"0 0 #{@width} #{@height}"}
      >
        <defs>
          <pattern id="gp-dots-v2" width="22" height="22" patternUnits="userSpaceOnUse">
            <circle cx="1" cy="1" r=".7" class="fill-mist-300" opacity=".55" />
          </pattern>
        </defs>
        <rect width={@width} height={@height} fill="url(#gp-dots-v2)" />
        <line
          :for={{x1, y1, x2, y2} <- @edges_xy}
          x1={x1}
          y1={y1}
          x2={x2}
          y2={y2}
          class="stroke-mist-700"
          stroke-width="1"
          opacity=".35"
        />
        <g :for={n <- @nodes_xy} transform={"translate(#{n.px},#{n.py})"}>
          <%= if n.type == "film" do %>
            <rect
              x={if n.big, do: -10, else: -6}
              y={if n.big, do: -10, else: -6}
              width={if n.big, do: 20, else: 12}
              height={if n.big, do: 20, else: 12}
              fill={if n.big, do: "#16140f", else: "#fafaf9"}
              stroke="#16140f"
              stroke-width="1.4"
              rx="2"
            />
          <% else %>
            <circle r={if n.big, do: 10, else: 6} fill="#fafaf9" stroke="#16140f" stroke-width="1.4" />
          <% end %>
          <text
            x={if n.big, do: 15, else: 11}
            y="3"
            font-size={if n.big, do: 12, else: 11}
            fill="#16140f"
            font-weight={if n.big, do: 700, else: 500}
            style="letter-spacing: -.005em"
          >
            {n.label}
          </text>
        </g>
      </svg>
      <div class="absolute top-[10px] left-3 flex items-center gap-[6px]">
        <span class="w-2 h-2 bg-mist-950"></span>
        <span class="text-[10.5px] text-mist-700 font-medium">Films</span>
        <span class="w-2 h-2 rounded-full border-[1.4px] border-mist-950 ml-2"></span>
        <span class="text-[10.5px] text-mist-700 font-medium">People</span>
      </div>
      <div class="absolute bottom-[10px] right-3 flex items-center gap-[6px] text-[10.5px] text-mist-500 tabular-nums">
        {length(@nodes_xy)} nodes · {length(@edges_xy)} edges · depth 2
      </div>
    </div>
    """
  end

  # ──────────────────────────────────────────────────────────────────
  # SHOW PAGE COMPONENTS (issue #757)
  # ──────────────────────────────────────────────────────────────────

  @doc """
  Score panel — 6-lens horizontal bar chart + overall + disparity badge.

  `:scores` is a map with lens keys (`:mob`, `:critics`, `:festival_recognition`,
  `:time_machine`, `:auteurs`, `:box_office`) plus `:overall`. Values are 0–10.
  """
  attr :scores, :map, required: true

  attr :weights, :map,
    default: %{
      mob: 10,
      critics: 10,
      festival_recognition: 20,
      time_machine: 20,
      auteurs: 20,
      box_office: 20
    }

  attr :disparity_label, :string, default: nil
  attr :disparity_summary, :string, default: nil

  def n_score_panel(assigns) do
    ~H"""
    <div class="bg-mist-50 border border-mist-950/10 rounded-[10px] p-6 lg:p-8">
      <div class="flex items-start justify-between gap-6 flex-wrap mb-6">
        <div>
          <.n_eyebrow>Cinegraph score</.n_eyebrow>
          <div class="flex items-baseline gap-3 mt-1">
            <div class="font-display italic text-[64px] tracking-[-.02em] text-mist-950 leading-none tabular-nums">
              {format_score(@scores[:overall])}
            </div>
            <div class="text-[14px] text-mist-500 tabular-nums">/ 10</div>
          </div>
          <div :if={@disparity_label} class="mt-2 flex items-center gap-2 flex-wrap">
            <span class="font-display italic text-[16px] text-mist-950">
              {@disparity_label}
            </span>
            <span :if={@disparity_summary} class="text-[12.5px] text-mist-700">
              — {@disparity_summary}
            </span>
          </div>
        </div>
      </div>

      <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-x-6 gap-y-4">
        <.n_score_bar
          label="The Mob"
          sublabel="audience"
          value={@scores[:mob]}
          weight={@weights[:mob]}
        />
        <.n_score_bar
          label="The Critics"
          sublabel="reviews"
          value={@scores[:critics]}
          weight={@weights[:critics]}
        />
        <.n_score_bar
          label="The Insiders"
          sublabel="festivals"
          value={@scores[:festival_recognition]}
          weight={@weights[:festival_recognition]}
        />
        <.n_score_bar
          label="Time Machine"
          sublabel="canon lists"
          value={@scores[:time_machine]}
          weight={@weights[:time_machine]}
        />
        <.n_score_bar
          label="The Auteurs"
          sublabel="talent"
          value={@scores[:auteurs]}
          weight={@weights[:auteurs]}
        />
        <.n_score_bar
          label="Box Office"
          sublabel="revenue"
          value={@scores[:box_office]}
          weight={@weights[:box_office]}
        />
      </div>
    </div>
    """
  end

  @doc "Single labeled lens bar — used inside `n_score_panel`."
  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :weight, :integer, default: nil
  attr :sublabel, :string, default: nil

  def n_score_bar(assigns) do
    val = score_for_bar(assigns.value)
    pct = score_pct(val)
    assigns = assigns |> assign(:val, val) |> assign(:pct, pct)

    ~H"""
    <div>
      <div class="flex items-baseline justify-between gap-2 mb-1">
        <div class="flex items-baseline gap-2">
          <span class="text-[13px] font-semibold text-mist-950 tracking-[-.005em]">{@label}</span>
          <span :if={@sublabel} class="text-[11px] text-mist-500">{@sublabel}</span>
        </div>
        <div class="flex items-baseline gap-2">
          <span class="text-[14px] font-semibold text-mist-950 tabular-nums">
            {format_score(@val)}
          </span>
          <span :if={@weight} class="text-[10px] text-mist-500 tabular-nums">{@weight}%</span>
        </div>
      </div>
      <div class="h-[5px] w-full bg-mist-950/[0.05] rounded-full overflow-hidden">
        <div class="h-full bg-mist-950" style={"width: #{@pct}%"}></div>
      </div>
    </div>
    """
  end

  defp score_for_bar(nil), do: nil
  defp score_for_bar(v) when is_number(v), do: v
  defp score_for_bar(_), do: nil

  defp score_pct(nil), do: 0
  defp score_pct(v) when is_number(v), do: round(min(max(v, 0), 10) * 10)

  defp format_score(nil), do: "—"

  defp format_score(v) when is_float(v),
    do: :erlang.float_to_binary(Float.round(v, 1), decimals: 1)

  defp format_score(v) when is_integer(v), do: "#{v}.0"
  defp format_score(v), do: to_string(v)

  @doc """
  Awards by org — a per-org card with winner stars and per-row category lines.

  `:nominations` is a list of maps, each with `:category`, `:year`, `:won`,
  optionally `:person_name`, `:film_title`, `:film_href`.
  """
  attr :org_name, :string, required: true
  attr :total_wins, :integer, default: 0
  attr :total_nominations, :integer, default: 0
  attr :nominations, :list, required: true

  def n_award_org_block(assigns) do
    ~H"""
    <section class="rounded-lg border border-mist-950/10 bg-mist-50 overflow-hidden">
      <header class="flex items-baseline justify-between gap-4 px-5 py-4 border-b border-mist-950/10 bg-mist-950/[0.025]">
        <h3 class="font-display italic text-[20px] tracking-[-.01em] text-mist-950 leading-tight">
          {@org_name}
        </h3>
        <div class="flex items-baseline gap-3 text-[11.5px] text-mist-700 tabular-nums shrink-0">
          <span :if={@total_wins > 0}>
            <b class="text-mist-950 font-semibold">{@total_wins}</b> {pluralize(@total_wins, "win")}
          </span>
          <span :if={@total_nominations > 0}>
            <b class="text-mist-950 font-semibold">{@total_nominations}</b>
            {pluralize(@total_nominations, "nomination")}
          </span>
        </div>
      </header>
      <ul role="list" class="divide-y divide-mist-950/[0.05]">
        <li :for={n <- @nominations} class="px-5 py-3 flex items-baseline gap-3">
          <span :if={n[:won]} class="text-amber-600 text-[12px] shrink-0" aria-label="Winner">★</span>
          <span :if={!n[:won]} class="w-[12px] shrink-0"></span>
          <div class="flex-1 min-w-0 text-[13px] text-mist-950">
            <span class="font-medium">{n.category}</span>
            <span :if={n[:person_name]} class="text-mist-700">
              <span class="mx-1">—</span>{n.person_name}
            </span>
            <span
              :if={n[:film_title]}
              class="text-mist-700"
            >
              for
              <a
                :if={n[:film_href]}
                href={n[:film_href]}
                class="underline decoration-mist-950/15 underline-offset-2 hover:text-mist-950"
              >
                {n.film_title}
              </a>
              <span :if={!n[:film_href]}>{n.film_title}</span>
            </span>
          </div>
          <div class="text-[11px] text-mist-500 tabular-nums shrink-0">
            {n[:year]}
            <span :if={n[:won]} class="text-amber-700 font-medium ml-1">winner</span>
            <span :if={!n[:won]}> · nominated</span>
          </div>
        </li>
      </ul>
    </section>
    """
  end

  defp pluralize(1, word), do: word
  defp pluralize(_, word), do: word <> "s"

  @doc """
  Credit row — used for cast / crew / filmography lists.

  `:credit` is a map with: `:avatar_url` or `:poster_url`, `:title` or `:name`,
  optional `:role`, `:character`, `:job`, `:year`, `:score`, `:href`,
  `:revenue`.
  """
  attr :credit, :map, required: true
  attr :variant, :string, default: "cast"

  def n_credit_row(assigns) do
    ~H"""
    <a
      href={@credit[:href] || "#"}
      class="flex items-center gap-3 px-3 py-2 -mx-3 rounded-md hover:bg-mist-950/[0.025] no-underline text-inherit"
    >
      <img
        :if={@credit[:avatar_url]}
        src={@credit.avatar_url}
        alt=""
        class="w-9 h-9 rounded-full shrink-0 border border-mist-950/10 object-cover bg-mist-100"
      />
      <img
        :if={@credit[:poster_url] && !@credit[:avatar_url]}
        src={@credit.poster_url}
        alt=""
        class="w-9 h-[54px] shrink-0 rounded-[3px] border border-mist-950/10 object-cover bg-mist-100"
      />
      <div
        :if={!@credit[:avatar_url] && !@credit[:poster_url]}
        class="w-9 h-9 rounded-full shrink-0 bg-mist-950/[0.05] grid place-items-center text-[10px] text-mist-500"
      >
        ?
      </div>
      <div class="flex-1 min-w-0">
        <div class="text-[13.5px] font-semibold text-mist-950 tracking-[-.005em] truncate">
          {@credit[:name] || @credit[:title]}
        </div>
        <div class="text-[11.5px] text-mist-700 truncate">
          <span :if={@credit[:character]}>{@credit.character}</span>
          <span :if={@credit[:job]}>{@credit.job}</span>
          <span :if={@credit[:role]}>{@credit.role}</span>
        </div>
      </div>
      <div :if={@credit[:year] || @credit[:score]} class="flex items-center gap-3 shrink-0">
        <span :if={@credit[:score]} class="text-[12px] font-bold text-mist-950 tabular-nums">
          {format_score(@credit.score)}
        </span>
        <span :if={@credit[:year]} class="text-[11.5px] text-mist-500 tabular-nums">
          {@credit.year}
        </span>
      </div>
    </a>
    """
  end

  @doc """
  Collaboration card — avatar pair + film count + strength bar + year span + avg score.

  `:collaboration` is a map with: `:person_a`, `:person_b`, `:films_together`,
  `:strength` (atom :very_strong | :strong | :moderate), `:year_range` (string),
  `:avg_score`, `:total_revenue`.
  """
  attr :collaboration, :map, required: true
  attr :anchor_person_id, :integer, default: nil

  def n_collaboration_card(assigns) do
    c = assigns.collaboration

    {strength_label, strength_pct, strength_classes} =
      case c[:strength] do
        :very_strong -> {"Very strong", 100, "bg-emerald-700"}
        :strong -> {"Strong", 66, "bg-emerald-600"}
        :moderate -> {"Moderate", 33, "bg-mist-700"}
        _ -> {"Moderate", 33, "bg-mist-700"}
      end

    assigns =
      assigns
      |> assign(:c, c)
      |> assign(:strength_label, strength_label)
      |> assign(:strength_pct, strength_pct)
      |> assign(:strength_classes, strength_classes)

    ~H"""
    <div class="block bg-mist-50 border border-mist-950/10 rounded-lg p-5 no-underline text-inherit">
      <div class="flex items-center gap-3 mb-3">
        <div class="flex -space-x-3 shrink-0">
          <img
            :if={@c[:avatar_a]}
            src={@c.avatar_a}
            alt=""
            class="w-10 h-10 rounded-full border-2 border-mist-50 object-cover bg-mist-100"
          />
          <img
            :if={@c[:avatar_b]}
            src={@c.avatar_b}
            alt=""
            class="w-10 h-10 rounded-full border-2 border-mist-50 object-cover bg-mist-100"
          />
        </div>
        <div class="flex-1 min-w-0">
          <% person_a = @c[:person_a] %>
          <% person_b = @c[:person_b] %>
          <div class="text-[13.5px] font-semibold text-mist-950 truncate">
            <.link
              :if={@c[:href]}
              navigate={@c.href}
              class="text-inherit underline decoration-mist-950/15 underline-offset-4 hover:decoration-mist-950/45"
            >
              <span :if={person_a}>{person_a} <span class="text-mist-500 mx-1">·</span></span>{person_b}
            </.link>
            <span :if={!@c[:href]}>
              <span :if={person_a}>{person_a} <span class="text-mist-500 mx-1">·</span></span>{person_b}
            </span>
          </div>
          <div class="text-[11.5px] text-mist-700">
            <b class="text-mist-950 font-semibold tabular-nums">{@c[:films_together]}</b>
            {pluralize(@c[:films_together] || 0, "film")} together
            <span :if={@c[:year_range]} class="text-mist-500">
              <span class="mx-1">·</span>{@c.year_range}
            </span>
          </div>
        </div>
      </div>

      <div class="flex items-center gap-2 mb-2">
        <div class="h-[4px] flex-1 bg-mist-950/[0.05] rounded-full overflow-hidden">
          <div class={["h-full", @strength_classes]} style={"width: #{@strength_pct}%"}></div>
        </div>
        <span class="text-[10.5px] text-mist-700 font-medium shrink-0">{@strength_label}</span>
      </div>

      <div
        :if={@c[:avg_score] || @c[:total_revenue]}
        class="flex items-center gap-4 text-[11px] text-mist-500 tabular-nums"
      >
        <span :if={@c[:avg_score]}>
          avg <b class="text-mist-950 font-semibold">{format_score(@c.avg_score)}</b>
        </span>
        <span :if={@c[:total_revenue] && @c.total_revenue > 0}>
          rev <b class="text-mist-950 font-semibold">${format_revenue(@c.total_revenue)}</b>
        </span>
      </div>

      <div :if={@c[:movies] && @c.movies != []} class="mt-3 pt-3 border-t border-mist-950/10">
        <div class="text-[10px] font-semibold text-mist-500 tracking-[.06em] uppercase mb-2">
          Films together
        </div>
        <div class="flex gap-2 overflow-x-auto">
          <.link
            :for={m <- @c.movies}
            navigate={"/movies-v2/#{m.slug || m.id}"}
            class="shrink-0 text-center no-underline text-inherit hover:opacity-75"
            title={m.title}
          >
            <div class="w-14 h-20 bg-mist-100 border border-mist-950/10 rounded grid place-items-center text-[11px] text-mist-700 tabular-nums">
              <%= if m.release_date do %>
                {m.release_date.year}
              <% else %>
                —
              <% end %>
            </div>
            <div :if={m.score} class="mt-1 text-[10.5px] font-semibold text-mist-950 tabular-nums">
              {Float.round(m.score, 1)}
            </div>
          </.link>
        </div>
      </div>
    </div>
    """
  end

  defp format_revenue(nil), do: "0"
  defp format_revenue(0), do: "0"

  defp format_revenue(n) when n >= 1_000_000_000 do
    "#{:erlang.float_to_binary(n / 1_000_000_000, decimals: 1)}B"
  end

  defp format_revenue(n) when n >= 1_000_000 do
    "#{:erlang.float_to_binary(n / 1_000_000, decimals: 1)}M"
  end

  defp format_revenue(n) when n >= 1_000 do
    "#{:erlang.float_to_binary(n / 1_000, decimals: 1)}K"
  end

  defp format_revenue(n), do: to_string(n)

  @doc """
  Vertical right-rail "On this page" TOC. Each entry is a map with `:id`,
  `:label`, `:present?`. Entries with `present?: false` are filtered out.

  Designed to live inside a sidebar column. Sticks within its parent on scroll.
  Active state is set by the `SectionNav` JS hook (IntersectionObserver on
  `[id]` sections matching `data-section-id`).
  """
  attr :sections, :list, required: true

  def n_section_nav(assigns) do
    assigns = assign(assigns, :visible, Enum.filter(assigns.sections, & &1.present?))

    ~H"""
    <nav
      :if={@visible != []}
      id="section-nav"
      phx-hook="SectionNav"
      class="sticky top-[80px]"
      aria-label="On this page"
    >
      <div class="text-[10.5px] font-semibold text-mist-500 tracking-[.06em] uppercase mb-3">
        On this page
      </div>
      <ul class="border-l border-mist-950/10">
        <li :for={s <- @visible}>
          <a
            href={"##{s.id}"}
            data-section-id={s.id}
            class="block pl-3 py-[6px] -ml-px text-[13px] no-underline border-l-2 border-transparent text-mist-700 hover:text-mist-950 [&.active]:border-mist-950 [&.active]:text-mist-950 [&.active]:font-medium"
          >
            {s.label}
          </a>
        </li>
      </ul>
    </nav>
    """
  end
end

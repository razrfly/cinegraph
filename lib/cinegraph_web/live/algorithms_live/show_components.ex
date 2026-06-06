defmodule CinegraphWeb.AlgorithmsLive.ShowComponents do
  @moduledoc """
  Function components for the `/algorithms/:slug` show page (#1038 2a/2b) — the poster-grid tabs,
  live probe, worst-misses and model-internals blocks. Pure rendering; all data is shaped by
  `AlgorithmsLive.Show` and every honesty gate (no fake %, prob only when certified) is applied
  upstream.
  """
  use CinegraphWeb, :html

  alias CinegraphWeb.NeutralV2Components

  # ── chips + view toggle (#1077) ─────────────────────────────────────────────────────
  attr :slug, :string, required: true
  attr :tab, :string, required: true
  attr :view, :string, required: true
  attr :member_count, :integer, required: true

  @doc """
  The unified view's filter chips (All / Predicted next / On the list) + the `[≡|▦]` view
  toggle. Chips patch without a `view` param so each tab gets its natural default (list for
  All, grid for the others); the toggle patches the current tab with an explicit view.
  """
  def chips_bar(assigns) do
    ~H"""
    <div class="flex items-center justify-between gap-3 border-b border-mist-950/10 dark:border-white/10">
      <div class="flex items-center gap-1">
        <.tab_link patch={~p"/algorithms/#{@slug}?tab=all"} active={@tab == "all"}>
          All
        </.tab_link>
        <.tab_link patch={~p"/algorithms/#{@slug}?tab=predictions"} active={@tab == "predictions"}>
          Predicted next
        </.tab_link>
        <.tab_link patch={~p"/algorithms/#{@slug}?tab=members"} active={@tab == "members"}>
          On the list ({@member_count})
        </.tab_link>
      </div>
      <div class="flex items-center gap-1 pb-1 text-[13px]">
        <.link
          patch={~p"/algorithms/#{@slug}?#{[tab: @tab, view: "list"]}"}
          aria-label="List view"
          class={view_toggle(@view == "list")}
        >
          ≡
        </.link>
        <.link
          patch={~p"/algorithms/#{@slug}?#{[tab: @tab, view: "grid"]}"}
          aria-label="Grid view"
          class={view_toggle(@view == "grid")}
        >
          ▦
        </.link>
      </div>
    </div>
    """
  end

  defp view_toggle(true),
    do: "px-2 py-[2px] rounded bg-mist-950 text-white dark:bg-white dark:text-mist-950"

  defp view_toggle(false),
    do:
      "px-2 py-[2px] rounded text-mist-500 hover:text-mist-900 dark:text-mist-400 dark:hover:text-white"

  attr :patch, :string, required: true
  attr :active, :boolean, required: true
  slot :inner_block, required: true

  defp tab_link(assigns) do
    ~H"""
    <.link
      patch={@patch}
      class={[
        "px-4 py-2 text-[13px] font-medium -mb-px border-b-2 transition",
        if(@active,
          do: "border-mist-950 text-mist-950 dark:border-white dark:text-white",
          else:
            "border-transparent text-mist-500 hover:text-mist-800 dark:text-mist-400 dark:hover:text-mist-200"
        )
      ]}
    >
      {render_slot(@inner_block)}
    </.link>
    """
  end

  # ── poster grid ───────────────────────────────────────────────────────────────────
  attr :films, :list, required: true
  attr :show_score, :boolean, default: false
  attr :ranked, :boolean, default: false
  attr :empty_text, :string, default: "Nothing to show."

  def film_grid(assigns) do
    ~H"""
    <div :if={@films == []} class="py-12 text-center text-[13px] text-mist-500 dark:text-mist-400">
      {@empty_text}
    </div>
    <div
      :if={@films != []}
      class="grid grid-cols-2 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-6 gap-[18px]"
    >
      <NeutralV2Components.n_film_card
        :for={film <- @films}
        film={film}
        rank={if(@ranked, do: film[:rank])}
        show_score={@show_score}
      />
    </div>
    """
  end

  # ── why expandable + list rows (#1077) ───────────────────────────────────────────
  attr :why, :list, required: true
  attr :signals_present, :integer, default: nil
  attr :total_features, :integer, default: nil

  @doc """
  The `[why ▾]` expandable — a film's exact linear model contributions (#1076 P1), with the
  signals-density disclosure. Pure `<details>`, no JS.
  """
  def why_details(assigns) do
    ~H"""
    <details :if={@why != []} class="mt-[2px]">
      <summary class="cursor-pointer select-none text-[11px] text-mist-400 hover:text-mist-700 dark:text-mist-500 dark:hover:text-mist-200">
        why ▾
      </summary>
      <div class="mt-1.5 max-w-md rounded-lg bg-mist-950/[0.03] dark:bg-white/[0.05] px-3 py-2">
        <ul class="space-y-1 text-[12px]">
          <li :for={t <- @why} class="flex items-center justify-between gap-3">
            <span class="text-mist-700 dark:text-mist-300">{t.label}</span>
            <span class="tabular-nums text-mist-500 dark:text-mist-400">
              {CinegraphWeb.AlgorithmsLive.Presentation.signed(t.contribution)}
            </span>
          </li>
        </ul>
        <div
          :if={@signals_present && @total_features}
          class={[
            "mt-1.5 text-[10.5px] tabular-nums",
            if(thin_evidence?(@signals_present),
              do: "text-amber-700 dark:text-amber-400",
              else: "text-mist-400 dark:text-mist-500"
            )
          ]}
        >
          {evidence_text(@signals_present, @total_features)}
        </div>
      </div>
    </details>
    """
  end

  attr :film, :map, required: true
  attr :rank, :integer, default: nil

  @doc """
  One row of the unified ranked list (#1077): poster thumb · title/year + `[why ▾]` ·
  ✓-member pill or #rank · model score. One score scale for members and predictions —
  that's the point.
  """
  def film_row(assigns) do
    ~H"""
    <div class="flex items-start gap-4 py-2.5 border-b border-mist-950/[0.06] dark:border-white/[0.06]">
      <a href={@film[:href] || "#"} class="block shrink-0">
        <div class="w-10 aspect-[2/3] rounded-[4px] overflow-hidden bg-mist-100 dark:bg-mist-800 border border-mist-950/10 dark:border-white/10">
          <img
            :if={@film[:poster_url]}
            src={@film.poster_url}
            alt=""
            loading="lazy"
            class="h-full w-full object-cover"
          />
        </div>
      </a>
      <div class="flex-1 min-w-0 pt-[2px]">
        <div class="flex items-baseline gap-2">
          <a
            href={@film[:href] || "#"}
            class="text-[13.5px] font-semibold text-mist-950 dark:text-white truncate"
          >
            {@film.title}
          </a>
          <span class="text-[12px] text-mist-500 dark:text-mist-400 tabular-nums shrink-0">
            {@film.year}
          </span>
          <span
            :if={@film[:also_on] not in [nil, []]}
            class="text-[10.5px] text-mist-400 dark:text-mist-500 truncate"
          >
            also on: {Enum.join(@film.also_on, ", ")}
          </span>
        </div>
        <.why_details
          why={@film[:why] || []}
          signals_present={@film[:signals_present]}
          total_features={@film[:total_features]}
        />
      </div>
      <div class="shrink-0 text-right pt-[2px]">
        <div class="flex items-center justify-end gap-2">
          <NeutralV2Components.n_pill :if={@film[:member?]} tone="ink" size="xs" class="">
            ✓ on the list
          </NeutralV2Components.n_pill>
          <span
            :if={!@film[:member?] && @rank}
            class="text-[11px] font-bold tabular-nums text-mist-500 dark:text-mist-400"
          >
            #{@rank}
          </span>
          <span class="text-[14px] font-semibold tabular-nums text-mist-950 dark:text-white">
            {format_row_score(@film[:score])}
          </span>
        </div>
        <div :if={@film[:prob_str]} class="text-[10.5px] text-mist-400 tabular-nums">
          {@film.prob_str}
        </div>
      </div>
    </div>
    """
  end

  defp format_row_score(s) when is_number(s), do: :erlang.float_to_binary(s * 1.0, decimals: 1)
  defp format_row_score(_), do: "—"

  # ── probe result (#1077 — the search lives in the unified list; this is just the card) ────
  attr :probe, :any, required: true

  @doc """
  The scored probe result card: honest score/prob, member/frontier pills, the exact why
  breakdown with the signals-density line, and the lens-profile context chips. The film was
  searched via the unified list search ("Not in this view — score it for this list").
  """
  def probe_result(assigns) do
    ~H"""
    <div
      :if={@probe == :loading}
      class="rounded-xl border border-mist-950/10 dark:border-white/10 bg-white dark:bg-mist-900 p-5 text-[12px] text-mist-400 animate-pulse"
    >
      scoring…
    </div>

    <div
      :if={is_map(@probe)}
      class="rounded-xl border border-mist-950/10 dark:border-white/10 bg-white dark:bg-mist-900 p-5"
    >
      <div class="flex flex-wrap items-center gap-3">
        <span class="text-[14px] font-semibold text-mist-950 dark:text-white">
          {@probe.title} <span class="font-normal text-mist-500">({@probe.year})</span>
        </span>
        <span
          :if={@probe.prob_str}
          class="font-display text-[26px] leading-none text-mist-950 dark:text-white tabular-nums"
        >
          {@probe.prob_str}
        </span>
        <span :if={!@probe.prob_str} class="text-[13px] text-mist-600 dark:text-mist-300">
          model score {@probe.score_str}/100 (probabilities not certified for display)
        </span>
        <NeutralV2Components.n_pill :if={@probe.member?} tone="ink" size="xs" class="">
          already on the list
        </NeutralV2Components.n_pill>
        <NeutralV2Components.n_pill
          :if={@probe.member? == false and @probe.eligible? == false}
          tone="amber"
          size="xs"
          class=""
        >
          pre-frontier — not a next-edition candidate
        </NeutralV2Components.n_pill>
        <button
          type="button"
          phx-click="probe_clear"
          class="text-[11px] underline text-mist-400 hover:text-mist-700 dark:hover:text-mist-200"
        >
          clear
        </button>
      </div>

      <div :if={@probe.why != []} class="mt-3">
        <div class="flex items-baseline justify-between gap-3 mb-1">
          <div class="text-[10px] uppercase tracking-wide text-mist-400 dark:text-mist-500">
            Why — exact model contributions
          </div>
          <span
            :if={@probe.present_features}
            class={[
              "text-[10.5px] tabular-nums",
              if(thin_evidence?(@probe.present_features),
                do: "text-amber-700 dark:text-amber-400",
                else: "text-mist-400 dark:text-mist-500"
              )
            ]}
          >
            {evidence_text(@probe.present_features, @probe.total_features)}
          </span>
        </div>
        <ul class="space-y-1 text-[12px] max-w-md">
          <li :for={t <- @probe.why} class="flex items-center justify-between gap-3">
            <span class="text-mist-700 dark:text-mist-300">{t.label}</span>
            <span class="tabular-nums text-mist-500 dark:text-mist-400">
              {CinegraphWeb.AlgorithmsLive.Presentation.signed(t.contribution)}
            </span>
          </li>
        </ul>
      </div>

      <div :if={@probe.lenses != []} class="mt-3">
        <div class="text-[10px] uppercase tracking-wide text-mist-400 dark:text-mist-500 mb-1">
          Its lens profile (context, not the model score)
        </div>
        <div class="flex flex-wrap gap-1.5">
          <span
            :for={{label, pct} <- @probe.lenses}
            class="text-[11px] rounded bg-mist-950/[0.04] px-2 py-[2px] text-mist-700 dark:bg-white/10 dark:text-mist-200 tabular-nums"
          >
            {label} {pct}%
          </span>
        </div>
      </div>
    </div>
    """
  end

  # ── worst misses (honesty) ────────────────────────────────────────────────────────
  attr :misses, :map, required: true

  def worst_misses(assigns) do
    ~H"""
    <div class="rounded-xl border border-mist-950/10 dark:border-white/10 bg-white dark:bg-mist-900 p-6">
      <NeutralV2Components.n_eyebrow>Worst misses (honesty)</NeutralV2Components.n_eyebrow>
      <p class="mt-1 text-[11px] text-mist-400 dark:text-mist-500">
        From the held-out evaluation — the member the model most underrated and the non-member it
        most overrated. We show our errors, not just our hits.
      </p>
      <dl class="mt-3 space-y-2 text-[13px]">
        <div :if={@misses["lowest_scored_member"]} class="flex justify-between gap-3">
          <dt class="text-mist-500 dark:text-mist-400">Underrated member</dt>
          <dd class="text-right text-mist-900 dark:text-mist-100">
            {@misses["lowest_scored_member"]["title"]}
            <span class="text-mist-400 tabular-nums">
              ({fmt_score(@misses["lowest_scored_member"]["score"])})
            </span>
          </dd>
        </div>
        <div :if={@misses["highest_scored_nonmember"]} class="flex justify-between gap-3">
          <dt class="text-mist-500 dark:text-mist-400">Overrated non-member</dt>
          <dd class="text-right text-mist-900 dark:text-mist-100">
            {@misses["highest_scored_nonmember"]["title"]}
            <span class="text-mist-400 tabular-nums">
              ({fmt_score(@misses["highest_scored_nonmember"]["score"])})
            </span>
          </dd>
        </div>
      </dl>
    </div>
    """
  end

  defp fmt_score(s) when is_number(s), do: "#{:erlang.float_to_binary(s * 1.0, decimals: 1)}/100"
  defp fmt_score(_), do: "—"

  # Evidence-density disclosure (#850 fold → #1077): a score built on a handful of signals is
  # honest but weakly grounded — say so where the score is shown. "Signals moving this score" is
  # intentional: it counts nonzero contribution terms, not populated features (a populated 0.0
  # derived feature moves nothing).
  defp thin_evidence?(present), do: is_integer(present) and present < 5

  defp evidence_text(present, total) do
    base = "signals moving this score: #{present} of #{total}"
    if thin_evidence?(present), do: base <> " — thin", else: base
  end

  # ── Dial 2: profile switcher + embedded tuner (#1038 2c — the resurrected /movies/discover) ──
  @lens_labels [
    {:mob, "The Mob", "Audience ratings (IMDb, TMDb)"},
    {:critics, "The Critics", "Tomatometer, Metacritic"},
    {:festival_recognition, "The Insiders", "Festival awards & nominations"},
    {:time_machine, "The Time Machine", "Canonical-list presence"},
    {:auteurs, "The Auteurs", "Director / cast / crew quality"},
    {:box_office, "The Box Office", "Revenue & ROI"}
  ]

  @doc false
  def lens_labels, do: @lens_labels

  attr :profile, :string, required: true
  attr :presets, :list, required: true
  attr :trained?, :boolean, default: true

  def profile_switcher(assigns) do
    ~H"""
    <div class="flex flex-wrap items-center gap-2">
      <span class="text-[11px] uppercase tracking-wide text-mist-400 dark:text-mist-500">
        Weight profile
      </span>
      <button
        :if={@trained?}
        type="button"
        phx-click="select_profile"
        phx-value-profile="trained"
        class={switch_pill(@profile == "trained")}
      >
        Trained model
      </button>
      <button
        :for={preset <- @presets}
        type="button"
        phx-click="select_profile"
        phx-value-profile={preset}
        class={switch_pill(@profile == preset)}
      >
        {humanize_preset(preset)}
      </button>
      <button
        type="button"
        phx-click="select_profile"
        phx-value-profile="custom"
        class={switch_pill(@profile == "custom")}
      >
        Custom…
      </button>
    </div>
    """
  end

  defp switch_pill(true),
    do:
      "px-3 py-1 rounded-full text-[12px] font-medium bg-mist-950 text-white dark:bg-white dark:text-mist-950"

  defp switch_pill(false),
    do:
      "px-3 py-1 rounded-full text-[12px] font-medium border border-mist-950/15 text-mist-700 hover:border-mist-950/40 dark:border-white/15 dark:text-mist-200 dark:hover:border-white/40"

  defp humanize_preset(p), do: p |> to_string() |> String.replace("_", " ") |> String.capitalize()

  attr :weights, :map, required: true
  attr :min_score, :float, required: true
  attr :unvalidated?, :boolean, default: true

  def tuner_panel(assigns) do
    assigns = assign(assigns, :lenses, @lens_labels)

    ~H"""
    <div class="rounded-xl border border-mist-950/10 dark:border-white/10 bg-white dark:bg-mist-900 p-6">
      <div class="flex items-baseline justify-between gap-3">
        <NeutralV2Components.n_eyebrow>Tune the lenses</NeutralV2Components.n_eyebrow>
        <button
          type="button"
          phx-click="reset_tuner"
          class="text-[11px] underline text-mist-400 hover:text-mist-700 dark:hover:text-mist-200"
        >
          Reset
        </button>
      </div>
      <p :if={@unvalidated?} class="mt-1 text-[11.5px] text-amber-700 dark:text-amber-400">
        Custom profiles are <strong>unvalidated</strong> — the accuracy above applies to the trained
        model only. This re-ranks live; it makes no accuracy claim.
      </p>

      <form phx-change="update_weights" class="mt-4 space-y-3">
        <div
          :for={{key, label, hint} <- @lenses}
          class="grid grid-cols-[140px_1fr_44px] items-center gap-3"
        >
          <div>
            <div class="text-[12.5px] font-medium text-mist-900 dark:text-mist-100">{label}</div>
            <div class="text-[10px] text-mist-400 dark:text-mist-500">{hint}</div>
          </div>
          <input
            type="range"
            name={key}
            min="0"
            max="100"
            value={round(Map.get(@weights, key, 0.0) * 100)}
            class="w-full accent-mist-950 dark:accent-white"
          />
          <span class="text-[12px] tabular-nums text-mist-500 dark:text-mist-400 text-right">
            {round(Map.get(@weights, key, 0.0) * 100)}%
          </span>
        </div>
      </form>

      <form phx-change="update_min_score" class="mt-4 flex items-center gap-3">
        <label class="text-[12px] text-mist-600 dark:text-mist-300">
          Min evidence (overall score ≥ {round(@min_score * 10)}%)
        </label>
        <input
          type="range"
          name="min_score"
          min="0"
          max="80"
          value={round(@min_score * 10)}
          class="w-40 accent-mist-950 dark:accent-white"
        />
      </form>
      <p class="mt-2 text-[10.5px] text-mist-400 dark:text-mist-500">
        Σ weights normalize to 100%. Films without enough evidence on a lens score 0 there — the
        min-evidence filter hides thinly-scored films rather than ranking them on a fake number.
      </p>
    </div>
    """
  end

  # ── recommendation rail (#1038 2b) ────────────────────────────────────────────────
  attr :list, :map, required: true

  def rail_thesis(assigns) do
    ~H"""
    <div class="rounded-xl border border-mist-950/10 dark:border-white/10 bg-white dark:bg-mist-900 p-6">
      <NeutralV2Components.n_eyebrow>How this rail thinks</NeutralV2Components.n_eyebrow>
      <p class="mt-2 text-[14px] text-mist-700 dark:text-mist-200">
        {rail_thesis_text(@list)}
      </p>
      <div class="mt-3 flex flex-wrap gap-2">
        <NeutralV2Components.n_pill tone="default" size="xs" class="">
          🌀 high unpredictability
        </NeutralV2Components.n_pill>
        <NeutralV2Components.n_pill tone="default" size="xs" class="">
          ⚔ critics-vs-crowd disagreement
        </NeutralV2Components.n_pill>
        <NeutralV2Components.n_pill tone="default" size="xs" class="">
          🕸 the people graph
        </NeutralV2Components.n_pill>
      </div>
      <p class="mt-3 text-[12px] text-mist-500 dark:text-mist-400">
        Deliberately <strong>not metadata-predictable</strong> — we measured it (#1070), and that's
        the point: these are the films collaborative filtering can't see.
      </p>
    </div>
    """
  end

  defp rail_thesis_text(%{metadata: %{"rail_thesis" => thesis}}) when is_binary(thesis),
    do: thesis

  defp rail_thesis_text(_list),
    do:
      "We don't use \"people who liked X also liked Y.\" We read the signals collaborative " <>
        "filtering can't: disagreement between critics and crowd, unpredictability across lenses, " <>
        "the people graph, and cult-list lineage."

  attr :query, :string, required: true
  attr :results, :list, required: true
  attr :seeds, :list, required: true

  def seed_picker(assigns) do
    ~H"""
    <div class="rounded-xl border border-mist-950/10 dark:border-white/10 bg-white dark:bg-mist-900 p-6">
      <NeutralV2Components.n_eyebrow>Start from a film you love</NeutralV2Components.n_eyebrow>
      <form phx-change="rail_search" phx-submit="rail_search" class="mt-3 relative max-w-md">
        <NeutralV2Components.n_filter_input
          id="rail_q"
          name="q"
          value={@query}
          placeholder="Search a film… (up to 3 seeds)"
          phx-debounce="300"
        />
        <div
          :if={@results != []}
          class="absolute z-10 mt-1 w-full rounded-lg border border-mist-950/10 dark:border-white/10 bg-white dark:bg-mist-900 shadow-lg overflow-hidden"
        >
          <button
            :for={f <- @results}
            type="button"
            phx-click="rail_seed"
            phx-value-slug={f.slug}
            class="block w-full text-left px-3 py-2 text-[13px] text-mist-900 dark:text-mist-100 hover:bg-mist-950/[0.04] dark:hover:bg-white/10"
          >
            {f.title} <span class="text-mist-400">({f[:year]})</span>
          </button>
        </div>
      </form>
      <div :if={@seeds != []} class="mt-3 flex flex-wrap gap-2">
        <span
          :for={s <- @seeds}
          class="inline-flex items-center gap-1.5 rounded-full bg-mist-950/[0.05] dark:bg-white/10 px-3 py-1 text-[12px] text-mist-900 dark:text-mist-100"
        >
          {s.title}
          <button
            type="button"
            phx-click="rail_seed_remove"
            phx-value-slug={s.slug}
            class="text-mist-400 hover:text-mist-900 dark:hover:text-white"
          >
            ✕
          </button>
        </span>
      </div>
    </div>
    """
  end
end

defmodule CinegraphWeb.AlgorithmsLive.Index do
  @moduledoc """
  Public `/algorithms` index (#1049 A1, #1038 Phase A) — honest per-list prediction reliability,
  split into the spec's two sections (the split *is* the honesty argument):

    * **Predictive models** — lists with a served model: honest grade (Wilson-95 lower bound of
      objective recall@K), recall, lift vs popularity, circularity flag, top objective signals.
    * **Recommendation rails** (`metadata["rail"]`) — no %, by design: a descriptor, never a number.
    * **Not metadata-predictable** — lists that honestly serve nothing.

  Data comes from `Cinegraph.Predictions.Explanation.for_list/1` (the read-model) — no number is
  invented here. Cards carry a 4-poster member strip (`Candidates.members/2`).
  """
  use CinegraphWeb, :live_view

  alias Cinegraph.Movies.MovieLists
  alias Cinegraph.Predictions.{Candidates, Explanation}
  alias CinegraphWeb.AlgorithmsLive.Presentation

  @strip_size 4

  @impl true
  def mount(_params, _session, socket) do
    # #1084: cards change only at promotion/catalog/data-drift boundaries — DisplayCache holds
    # them (single-flight, model-identity keys, 15-min TTL) so dead+live mounts are cache hits.
    cards = Cinegraph.Predictions.DisplayCache.index_cards(&build_cards/0)
    groups = Enum.group_by(cards, & &1.kind)

    {:ok,
     socket
     |> assign(:page_title, "Algorithms")
     |> assign(:active_nav, "Algorithms")
     |> assign(:card_count, length(cards))
     |> assign(:predictive_cards, sort_predictive(groups[:predictive] || []))
     |> assign(:rail_cards, Enum.sort_by(groups[:rail] || [], & &1.name))
     |> assign(:unserved_cards, Enum.sort_by(groups[:unserved] || [], & &1.name))
     |> assign(:served_count, length(groups[:predictive] || []))}
  end

  # ── data assembly (read-only; cheap — ~3 queries/list, no caching needed) ──────────
  defp build_cards do
    MovieLists.all_displayable()
    |> Enum.map(&build_card/1)
  end

  defp build_card(list) do
    base = %{
      name: list.name,
      slug: list.slug,
      source_key: list.source_key,
      archetype: Presentation.archetype(list.source_key),
      posters: poster_strip(list.source_key)
    }

    cond do
      # Rails are presented as what they are — a recommendation engine, not a failed prediction.
      is_map(list.metadata) and list.metadata["rail"] == true ->
        Map.merge(base, %{kind: :rail, tier: "Recommendation rail", tier_tone: "ink"})

      true ->
        case Explanation.for_list(list.source_key) do
          {:ok, e} ->
            Map.merge(base, %{
              kind: :predictive,
              grade: e.grade,
              tier: Presentation.tier(e.grade),
              tier_tone: Presentation.tier_tone(e.grade),
              headline_pct: e.headline_accuracy,
              recall: e.lift && e.lift.recall,
              lift_ratio: e.lift && e.lift.ratio,
              lift_passes?: e.lift && e.lift.passes?,
              circularity: e.circularity,
              strategy: e.strategy,
              top_features: e.weights |> Enum.filter(&(&1.bucket == :objective)) |> Enum.take(4)
            })

          {:error, :no_active_model} ->
            Map.merge(base, %{
              kind: :unserved,
              tier: "Not metadata-predictable",
              tier_tone: "default"
            })
        end
    end
  end

  defp poster_strip(source_key) do
    source_key
    |> Candidates.members(limit: @strip_size)
    |> Enum.map(&Presentation.poster_url(&1.poster_path))
    |> Enum.reject(&is_nil/1)
  end

  # Predictive cards by recall (point estimate) desc.
  defp sort_predictive(cards), do: Enum.sort_by(cards, &(-(&1.recall || 0.0)))

  # ── card components ────────────────────────────────────────────────────────────────
  attr :posters, :list, required: true

  @doc false
  def poster_strip_row(assigns) do
    ~H"""
    <div :if={@posters != []} class="flex gap-1.5">
      <div
        :for={url <- @posters}
        class="aspect-[2/3] w-0 flex-1 overflow-hidden rounded-[4px] bg-mist-100 dark:bg-mist-800 border border-mist-950/10 dark:border-white/10"
      >
        <img src={url} alt="" loading="lazy" class="h-full w-full object-cover" />
      </div>
    </div>
    """
  end

  # ── presentation helpers (used by the template) ───────────────────────────────────
  @doc false
  def pct(n) when is_number(n), do: "#{:erlang.float_to_binary(n * 1.0, decimals: 0)}%"
  def pct(_), do: "—"

  @doc false
  def headline(n) when is_number(n), do: "#{:erlang.float_to_binary(n * 1.0, decimals: 1)}%"
  def headline(other), do: to_string(other)

  @doc false
  # Ratio is only meaningful when the popularity baseline is > 0; when it's ~0 (popularity finds
  # essentially none), fall back to the pass/fail margin so we don't misreport a real win as "no lift".
  def lift_text(r, _passes?) when is_number(r) and r > 0.0,
    do: "#{:erlang.float_to_binary(r * 1.0, decimals: 1)}× vs popularity"

  def lift_text(_r, true), do: "beats the popularity baseline"
  def lift_text(_r, _passes?), do: "no lift over popularity"

  @doc false
  def circularity_pct(c) when is_number(c), do: "#{round(c * 100)}%"
  def circularity_pct(_), do: nil
end

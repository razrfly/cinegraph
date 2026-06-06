defmodule CinegraphWeb.AlgorithmsLive.Index do
  @moduledoc """
  Public `/algorithms` index (#1049 A1) — honest per-list prediction reliability.

  One card per canonical list: lists with a served model show their honest grade (Wilson-95 lower
  bound of objective recall@K), recall, lift vs popularity, circularity flag, and top objective
  signals; lists that serve no model are shown honestly as **not metadata-predictable**. Data comes
  from `Cinegraph.Predictions.Explanation.for_list/1` (the read-model) — no number is invented here.
  """
  use CinegraphWeb, :live_view

  alias Cinegraph.Movies.MovieLists
  alias Cinegraph.Predictions.Explanation

  # Rough archetype tags (#1070) — purely for honest grouping/context in the UI.
  @archetype %{
    "afi_100" => "Consensus",
    "1001_movies" => "Consensus",
    "national_film_registry" => "Consensus",
    "sight_sound_critics_2022" => "Consensus",
    "sight_sound_directors_2022" => "Consensus",
    "tspdt_1000" => "Auteur",
    "criterion" => "Auteur",
    "ebert_great_movies" => "Auteur",
    "cult_movies_400" => "Taste",
    "letterboxd_top_250" => "Taste"
  }

  @impl true
  def mount(_params, _session, socket) do
    cards = build_cards()

    {:ok,
     socket
     |> assign(:page_title, "Algorithms")
     |> assign(:active_nav, "Algorithms")
     |> assign(:cards, cards)
     |> assign(:served_count, Enum.count(cards, & &1.served?))}
  end

  # ── data assembly (read-only; cheap — ~2 queries/list, no caching needed) ──────────
  defp build_cards do
    MovieLists.all_displayable()
    |> Enum.map(&build_card/1)
    |> Enum.sort_by(&sort_key/1)
  end

  defp build_card(list) do
    base = %{
      name: list.name,
      slug: list.slug,
      source_key: list.source_key,
      archetype: Map.get(@archetype, list.source_key, "—")
    }

    case Explanation.for_list(list.source_key) do
      {:ok, e} ->
        Map.merge(base, %{
          served?: true,
          grade: e.grade,
          tier: tier(e.grade),
          tier_tone: tier_tone(e.grade),
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
          served?: false,
          grade: nil,
          tier: "Not metadata-predictable",
          tier_tone: "default"
        })
    end
  end

  # Served lists first, then by recall (point estimate) desc; unserved last, alphabetical.
  defp sort_key(%{served?: true, recall: r}), do: {0, -(r || 0.0), ""}
  defp sort_key(%{served?: false, name: n}), do: {1, 0.0, n}

  defp tier(:high), do: "Strong"
  defp tier(:moderate), do: "Moderate"
  defp tier(:low), do: "Low"
  defp tier(_), do: "Insufficient"

  defp tier_tone(:high), do: "green"
  defp tier_tone(:moderate), do: "blue"
  defp tier_tone(:low), do: "amber"
  defp tier_tone(_), do: "default"

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

defmodule CinegraphWeb.AlgorithmsLive.Show do
  @moduledoc """
  Public `/algorithms/:slug` show page (#1038) — the full honest explanation of one list's served
  prediction model: grade, recall, lift, circularity, the complete weight breakdown (each weight
  tagged objective vs canon-overlap with a human label), and the rival configurations we evaluated.
  Lists with no served model render the honest "not metadata-predictable" explanation.

  Data is `Cinegraph.Predictions.Explanation.for_list/1` — no number is invented in the view.
  """
  use CinegraphWeb, :live_view

  alias Cinegraph.Movies.MovieLists
  alias Cinegraph.Predictions.Explanation

  # Cap the on-page weight list; the rest are summarized.
  @max_weights 18

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
  def mount(_params, _session, socket), do: {:ok, assign(socket, :active_nav, "Algorithms")}

  @impl true
  def handle_params(%{"slug" => slug}, _url, socket) do
    case MovieLists.get_by_slug(slug) do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, "Algorithm list not found")
         |> push_navigate(to: ~p"/algorithms")}

      list ->
        {:noreply,
         socket
         |> assign(:page_title, list.name)
         |> assign(:list, list)
         |> assign(:archetype, Map.get(@archetype, list.source_key, "—"))
         |> assign(:view, view_for(list))}
    end
  end

  # Display-ready payload: served detail (with grouped/capped weights) or the unserved honest state.
  defp view_for(list) do
    case Explanation.for_list(list.source_key) do
      {:error, :no_active_model} ->
        %{served?: false}

      {:ok, e} ->
        weights = e.weights || []
        shown = Enum.take(weights, @max_weights)
        max_abs = weights |> Enum.map(&abs(&1.weight)) |> Enum.max(fn -> 1.0 end)

        %{
          served?: true,
          grade: e.grade,
          tier: tier(e.grade),
          tier_tone: tier_tone(e.grade),
          headline_pct: e.headline_accuracy,
          recall: e.lift && e.lift.recall,
          lift_ratio: e.lift && e.lift.ratio,
          lift_passes?: e.lift && e.lift.passes?,
          circularity: e.circularity,
          model_label: e.model_label,
          strategy: e.strategy,
          shown_weights: shown,
          shown_count: length(shown),
          total_weights: length(weights),
          max_abs: max_abs,
          objective_count: Enum.count(weights, &(&1.bucket == :objective)),
          canon_count: Enum.count(weights, &(&1.bucket == :canon_overlap)),
          rivals: e.rivals || []
        }
    end
  end

  defp tier(:high), do: "Strong"
  defp tier(:moderate), do: "Moderate"
  defp tier(:low), do: "Low"
  defp tier(_), do: "Insufficient"

  defp tier_tone(:high), do: "green"
  defp tier_tone(:moderate), do: "blue"
  defp tier_tone(:low), do: "amber"
  defp tier_tone(_), do: "default"

  # ── presentation helpers (template) ────────────────────────────────────────────────
  @doc false
  def headline(n) when is_number(n), do: "#{:erlang.float_to_binary(n * 1.0, decimals: 1)}%"
  def headline(other), do: to_string(other)

  @doc false
  def pct(n) when is_number(n), do: "#{:erlang.float_to_binary(n * 1.0, decimals: 0)}%"
  def pct(_), do: "—"

  @doc false
  def weight_pct(n) when is_number(n), do: "#{:erlang.float_to_binary(n * 100.0, decimals: 1)}"
  def weight_pct(_), do: "0.0"

  @doc false
  def lift_text(r, _passes?) when is_number(r) and r > 0.0,
    do: "#{:erlang.float_to_binary(r * 1.0, decimals: 1)}× vs popularity"

  def lift_text(_r, true), do: "beats the popularity baseline"
  def lift_text(_r, _passes?), do: "no lift over popularity"

  @doc false
  def circularity_pct(c) when is_number(c), do: "#{round(c * 100)}%"
  def circularity_pct(_), do: nil

  @doc false
  def bar_width(weight, max_abs) when is_number(weight) and is_number(max_abs) and max_abs > 0.0,
    do: "#{Float.round(abs(weight) / max_abs * 100, 1)}%"

  def bar_width(_, _), do: "0%"

  @doc false
  def rival_recall(r) when is_number(r), do: "#{:erlang.float_to_binary(r * 100.0, decimals: 1)}%"
  def rival_recall(_), do: "—"
end

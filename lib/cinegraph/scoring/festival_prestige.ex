defmodule Cinegraph.Scoring.FestivalPrestige do
  @moduledoc """
  Single source of truth for festival prestige tiers used across all scoring systems.

  Tiers are on a 0–100 scale. The `ceiling` parameter in `score_nominations/2`
  controls the cap — 100.0 for CriteriaScoring (predictions), 10.0 for MovieScoring
  (show page). Since CriteriaScoring values are exactly 10× MovieScoring values,
  passing `ceiling: 10.0` naturally scales the result.
  """

  @tiers %{
    "AMPAS" => {100.0, 80.0},
    "CFF" => {95.0, 75.0},
    "VIFF" => {90.0, 70.0},
    "BIFF" => {90.0, 70.0},
    "BAFTA" => {85.0, 65.0},
    "HFPA" => {80.0, 60.0},
    "SFF" => {75.0, 60.0},
    "CCA" => {70.0, 50.0}
  }
  @default_tier {0.0, 0.0}
  @category_boost 10.0
  @major_categories ["picture", "film", "director"]

  @doc """
  Score a single nomination. Returns a value on the 0–110 scale (before ceiling cap).

  When `db_win_score` and `db_nom_score` are provided (non-nil numbers), they take
  precedence over `@tiers`. Pass nil to fall back to the hard-coded tiers.
  """
  def score_nomination(
        festival_abbrev,
        category_name,
        won,
        db_win_score \\ nil,
        db_nom_score \\ nil
      ) do
    {default_win, default_nom} = Map.get(@tiers, festival_abbrev, @default_tier)
    win_score = if is_number(db_win_score), do: db_win_score, else: default_win
    nom_score = if is_number(db_nom_score), do: db_nom_score, else: default_nom

    base = if won, do: win_score, else: nom_score

    boost =
      if String.contains?(String.downcase(category_name || ""), @major_categories),
        do: @category_boost,
        else: 0.0

    base + boost
  end

  @doc """
  Score a list of nominations as [[abbrev, category, won | _tail], ...].

  `ceiling` controls the cap and scale:
  - 100.0 (default) for CriteriaScoring/predictions
  - 10.0 for MovieScoring/show page

  When rows contain win_score and nom_score at positions 4–5 (from a DB JOIN that
  SELECTs `fo.win_score, fo.nom_score`), those values are used instead of `@tiers`.
  Extra tail elements are ignored, preserving backward compatibility.
  """
  def score_nominations(nominations, ceiling \\ 100.0) do
    nominations
    |> Enum.map(fn [festival, category, won | tail] ->
      [db_win, db_nom | _] = tail ++ [nil, nil]
      score_nomination(festival, category, won, db_win, db_nom)
    end)
    |> Enum.sum()
    |> then(&min(&1 * (ceiling / 100.0), ceiling))
  end

  @doc "Expose tiers for SQL generation (used by ScoringService)."
  def tiers, do: @tiers

  @doc "Expose default tier for SQL generation."
  def default_tier, do: @default_tier

  @doc "Boost applied to major category nominations."
  def category_boost, do: @category_boost

  @doc "Category name substrings that trigger the prestige boost."
  def major_categories, do: @major_categories
end

defmodule Cinegraph.Movies.ScoreabilityRules do
  @moduledoc """
  Pure scoreability rules used when a movie score cache is recalculated in memory.
  """

  @lens_count 6

  def build_scoreability_from_scores(sd) do
    c = sd.components

    lens_scores = [
      {"mob", c.mob},
      {"critics", c.critics},
      {"festival_recognition", c.festival_recognition},
      {"time_machine", c.time_machine},
      {"auteurs", c.auteurs},
      {"box_office", c.box_office}
    ]

    present =
      lens_scores
      |> Enum.filter(fn {_key, value} -> is_number(value) and value > 0 end)
      |> Enum.map(&elem(&1, 0))

    missing =
      lens_scores
      |> Enum.reject(fn {_key, value} -> is_number(value) and value > 0 end)
      |> Enum.map(&elem(&1, 0))

    present_count = length(present)
    evidence_confidence = Float.round(present_count / @lens_count, 3)
    display_score = if present_count >= 2, do: sd.overall_score
    sort_score = if display_score, do: display_score * evidence_confidence

    %{
      raw_cinegraph_score: sd.overall_score,
      legacy_score_confidence: sd.score_confidence,
      present_lens_count: present_count,
      missing_lens_count: length(missing),
      present_lens_labels: present,
      missing_lens_labels: missing,
      evidence_confidence: evidence_confidence,
      scoreability_state: scoreability_state(sd.overall_score, present_count),
      score_confidence_label:
        score_confidence_label(sd.overall_score, present_count, evidence_confidence),
      cinegraph_display_score: display_score,
      cinegraph_sort_score: sort_score,
      score_hidden_reason: score_hidden_reason(sd.overall_score, present_count),
      score_explanation_short:
        score_explanation_short(sd.overall_score, present_count, evidence_confidence),
      score_explanation_detail: score_explanation_detail(sd.overall_score, present_count)
    }
  end

  def scoreability_state(nil, _count), do: "insufficient_evidence"
  def scoreability_state(_score, count) when count >= 4, do: "scoreable"
  def scoreability_state(_score, count) when count >= 2, do: "limited"
  def scoreability_state(_score, _count), do: "insufficient_evidence"

  def score_confidence_label(nil, _count, _confidence), do: "insufficient"
  def score_confidence_label(_score, count, _confidence) when count <= 1, do: "insufficient"

  def score_confidence_label(_score, count, confidence) when confidence >= 0.70 or count >= 5,
    do: "high"

  def score_confidence_label(_score, count, confidence) when confidence >= 0.35 or count >= 3,
    do: "medium"

  def score_confidence_label(_score, _count, _confidence), do: "low"

  def score_hidden_reason(nil, _count), do: "no_score_cache"
  def score_hidden_reason(_score, count) when count <= 1, do: "not_enough_evidence"
  def score_hidden_reason(_score, _count), do: "none"

  def score_explanation_short(nil, _count, _confidence), do: "Not enough evidence yet"

  def score_explanation_short(_score, count, _confidence) when count <= 1,
    do: "Not enough evidence yet"

  def score_explanation_short(_score, count, _confidence) when count <= 3,
    do: "Limited confidence"

  def score_explanation_short(_score, count, confidence) when confidence >= 0.70 or count >= 5,
    do: "High confidence"

  def score_explanation_short(_score, _count, _confidence), do: "Medium confidence"

  def score_explanation_detail(nil, _count),
    do: "No CineGraph score cache is available for this movie yet."

  def score_explanation_detail(_score, count) when count <= 1 do
    "CineGraph needs at least 2 independent evidence lenses before showing a fair numeric score."
  end

  def score_explanation_detail(_score, count) when count <= 3 do
    "This score is based on limited evidence and may move as more lenses become available."
  end

  def score_explanation_detail(_score, _count) do
    "This movie has enough independent evidence for a CineGraph score."
  end
end

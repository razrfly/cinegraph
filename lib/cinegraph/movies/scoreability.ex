defmodule Cinegraph.Movies.Scoreability do
  @moduledoc """
  Presentation helpers for the CineGraph scoreability contract.

  These helpers intentionally mirror the database view's product states without
  recalculating the core SQL rules.
  """

  @lens_labels %{
    "mob" => "Audience",
    "critics" => "Critics",
    "festival_recognition" => "Festival",
    "time_machine" => "Time Machine",
    "auteurs" => "Auteurs",
    "box_office" => "Box Office"
  }

  def display_score(%{cinegraph_display_score: score}) when is_number(score), do: score
  def display_score(%{scoreability: scoreability}), do: display_score(scoreability)
  def display_score(_), do: nil

  def raw_score(%{raw_cinegraph_score: score}) when is_number(score), do: score
  def raw_score(%{scoreability: scoreability}), do: raw_score(scoreability)
  def raw_score(%{overall_score: score}) when is_number(score), do: score
  def raw_score(%{score_cache: %{overall_score: score}}) when is_number(score), do: score
  def raw_score(_), do: nil

  def state(%{scoreability_state: state}) when is_binary(state), do: state
  def state(%{scoreability: scoreability}), do: state(scoreability)
  def state(_), do: "insufficient_evidence"

  def confidence_label(%{score_confidence_label: label}) when is_binary(label), do: label
  def confidence_label(%{scoreability: scoreability}), do: confidence_label(scoreability)
  def confidence_label(_), do: "insufficient"

  def present_lens_count(%{present_lens_count: count}) when is_integer(count), do: count
  def present_lens_count(%{scoreability: scoreability}), do: present_lens_count(scoreability)
  def present_lens_count(_), do: 0

  def missing_lens_count(%{missing_lens_count: count}) when is_integer(count), do: count
  def missing_lens_count(%{scoreability: scoreability}), do: missing_lens_count(scoreability)
  def missing_lens_count(_), do: 6

  def present_lens_labels(%{present_lens_labels: labels}) when is_list(labels), do: labels
  def present_lens_labels(%{scoreability: scoreability}), do: present_lens_labels(scoreability)
  def present_lens_labels(_), do: []

  def missing_lens_labels(%{missing_lens_labels: labels}) when is_list(labels), do: labels
  def missing_lens_labels(%{scoreability: scoreability}), do: missing_lens_labels(scoreability)
  def missing_lens_labels(_), do: []

  def short_explanation(%{score_explanation_short: copy}) when is_binary(copy), do: copy
  def short_explanation(%{scoreability: scoreability}), do: short_explanation(scoreability)

  def short_explanation(value) do
    case state(value) do
      "scoreable" -> "#{human_confidence(value)} confidence"
      "limited" -> "Limited confidence"
      _ -> "Not enough evidence yet"
    end
  end

  def detail_explanation(%{score_explanation_detail: copy}) when is_binary(copy), do: copy
  def detail_explanation(%{scoreability: scoreability}), do: detail_explanation(scoreability)

  def detail_explanation(value) do
    count = present_lens_count(value)

    cond do
      count <= 1 ->
        "CineGraph needs at least 2 independent evidence lenses before showing a fair numeric score."

      count <= 3 ->
        "This score is based on #{count} of 6 evidence lenses and may move as more evidence becomes available."

      true ->
        "This movie has #{count} of 6 evidence lenses available."
    end
  end

  def hidden_reason(%{score_hidden_reason: reason}) when is_binary(reason), do: reason
  def hidden_reason(%{scoreability: scoreability}), do: hidden_reason(scoreability)
  def hidden_reason(_), do: "not_enough_evidence"

  def confidence_badge(value) do
    case state(value) do
      "scoreable" -> "#{human_confidence(value)} confidence"
      "limited" -> "Limited confidence"
      _ -> "Not enough evidence yet"
    end
  end

  def lens_summary(value) do
    "#{present_lens_count(value)} of 6 evidence lenses"
  end

  def human_lens_label(key), do: Map.get(@lens_labels, to_string(key), to_string(key))

  def human_lens_labels(labels) when is_list(labels), do: Enum.map(labels, &human_lens_label/1)
  def human_lens_labels(_), do: []

  defp human_confidence(value) do
    value
    |> confidence_label()
    |> case do
      "high" -> "High"
      "medium" -> "Medium"
      "low" -> "Low"
      _ -> "Insufficient"
    end
  end
end

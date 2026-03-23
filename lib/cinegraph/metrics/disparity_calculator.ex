defmodule Cinegraph.Metrics.DisparityCalculator do
  @moduledoc """
  Pure calculations for disparity and unpredictability scores.
  No DB calls — all inputs come from MovieScoring.calculate_movie_scores/1.
  """

  # Thresholds from issue #615
  @significant_disparity 2.0
  @harmony_threshold 0.5
  @high_score_threshold 7.5
  @low_score_threshold 5.5

  @doc "Calculate |mob - ivory_tower| on 0–10 scale."
  def calculate_disparity(mob, ivory_tower), do: abs(mob - ivory_tower)

  @doc """
  Classify the disparity into a named category.
  Returns nil when disparity is not significant enough to categorize.
  """
  def classify_disparity(mob, ivory_tower, disparity) do
    cond do
      ivory_tower > @high_score_threshold and mob < @low_score_threshold and
          disparity > @significant_disparity ->
        "critics_darling"

      mob > @high_score_threshold and ivory_tower < @low_score_threshold and
          disparity > @significant_disparity ->
        "peoples_champion"

      mob > @high_score_threshold and ivory_tower > @high_score_threshold and
          disparity < @harmony_threshold ->
        "perfect_harmony"

      disparity > @significant_disparity ->
        "polarizer"

      true ->
        nil
    end
  end

  @doc "Population stddev of all 6 lens scores (0–10 scale each)."
  def calculate_unpredictability(%{
        mob: mob,
        ivory_tower: ivory,
        industry_recognition: industry,
        cultural_impact: cultural,
        people_quality: people,
        financial_performance: financial
      }) do
    scores = [mob, ivory, industry, cultural, people, financial]
    population_stddev(scores)
  end

  @doc """
  Given the output of MovieScoring.calculate_movie_scores/1,
  returns %{disparity_score, disparity_category, unpredictability_score}.
  Returns nil disparity values when both mob and ivory_tower scores are 0 (no data).
  """
  def calculate_all(%{components: c}) do
    mob = c.mob
    ivory = c.ivory_tower

    {disparity, category} =
      if mob == 0.0 and ivory == 0.0 do
        {nil, nil}
      else
        d = calculate_disparity(mob, ivory)
        {Float.round(d, 2), classify_disparity(mob, ivory, d)}
      end

    unpredictability = Float.round(calculate_unpredictability(c), 2)

    %{
      disparity_score: disparity,
      disparity_category: category,
      unpredictability_score: unpredictability
    }
  end

  defp population_stddev(scores) do
    n = length(scores)

    if n < 2 do
      0.0
    else
      mean = Enum.sum(scores) / n
      variance = Enum.sum(Enum.map(scores, fn x -> (x - mean) ** 2 end)) / n
      :math.sqrt(variance)
    end
  end
end

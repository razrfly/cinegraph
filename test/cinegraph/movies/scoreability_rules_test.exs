defmodule Cinegraph.Movies.ScoreabilityRulesTest do
  use ExUnit.Case, async: true

  alias Cinegraph.Movies.ScoreabilityRules

  describe "build_scoreability_from_scores/1" do
    test "marks warm-enough scores as scoreable with high confidence" do
      scoreability =
        ScoreabilityRules.build_scoreability_from_scores(%{
          overall_score: 8.2,
          score_confidence: 0.77,
          components: %{
            mob: 8.0,
            critics: 8.5,
            festival_recognition: 7.2,
            time_machine: 6.8,
            auteurs: 7.9,
            box_office: 0.0
          }
        })

      assert scoreability.scoreability_state == "scoreable"
      assert scoreability.score_confidence_label == "high"
      assert scoreability.cinegraph_display_score == 8.2
      assert scoreability.cinegraph_sort_score == 8.2 * 0.833
      assert scoreability.evidence_confidence == 0.833
      assert scoreability.present_lens_count == 5
      assert scoreability.missing_lens_labels == ["box_office"]
      assert scoreability.score_hidden_reason == "none"
    end

    test "keeps sparse cold-cache scores hidden until enough lenses are present" do
      scoreability =
        ScoreabilityRules.build_scoreability_from_scores(%{
          overall_score: 6.4,
          score_confidence: 0.2,
          components: %{
            mob: nil,
            critics: 6.4,
            festival_recognition: 0.0,
            time_machine: nil,
            auteurs: nil,
            box_office: nil
          }
        })

      assert scoreability.scoreability_state == "insufficient_evidence"
      assert scoreability.score_confidence_label == "insufficient"
      assert scoreability.cinegraph_display_score == nil
      assert scoreability.cinegraph_sort_score == nil
      assert scoreability.evidence_confidence == 0.167
      assert scoreability.present_lens_count == 1
      assert scoreability.present_lens_labels == ["critics"]
      assert scoreability.score_hidden_reason == "not_enough_evidence"
      assert scoreability.score_explanation_short == "Not enough evidence yet"
    end

    test "represents missing overall scores as no score cache" do
      scoreability =
        ScoreabilityRules.build_scoreability_from_scores(%{
          overall_score: nil,
          score_confidence: nil,
          components: %{
            mob: nil,
            critics: nil,
            festival_recognition: nil,
            time_machine: nil,
            auteurs: nil,
            box_office: nil
          }
        })

      assert scoreability.scoreability_state == "insufficient_evidence"
      assert scoreability.score_confidence_label == "insufficient"
      assert scoreability.score_hidden_reason == "no_score_cache"

      assert scoreability.score_explanation_detail ==
               "No CineGraph score cache is available for this movie yet."
    end
  end
end

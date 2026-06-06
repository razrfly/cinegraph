defmodule CinegraphWeb.AlgorithmsLive.Presentation do
  @moduledoc """
  Shared presentation vocabulary for the `/algorithms` pages (#1049/#1038) — the per-list archetype
  tags and the reliability-grade → display tier/tone mapping, used by both `AlgorithmsLive.Index`
  and `AlgorithmsLive.Show` so the two views can't drift.
  """

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

  @doc "Archetype tag for a list's `source_key` (`\"—\"` when unknown)."
  def archetype(source_key), do: Map.get(@archetype, source_key, "—")

  @doc "Display tier for a `Reliability` grade atom."
  def tier(:high), do: "Strong"
  def tier(:moderate), do: "Moderate"
  def tier(:low), do: "Low"
  def tier(_), do: "Insufficient"

  @doc "`n_pill` tone for a `Reliability` grade atom."
  def tier_tone(:high), do: "green"
  def tier_tone(:moderate), do: "blue"
  def tier_tone(:low), do: "amber"
  def tier_tone(_), do: "default"

  @doc """
  Format a calibrated probability (0..1) for a film badge. Next-edition probabilities are honestly
  tiny (base rate ~0.1%), so integer rounding would render every card as a broken-looking "0%" —
  keep one decimal below 10%, and floor the display at "<0.1%" rather than fake a zero.
  """
  def prob_str(p) when is_number(p) do
    pct = p * 100

    cond do
      pct >= 10 -> "#{round(pct)}%"
      pct >= 0.05 -> "#{:erlang.float_to_binary(pct * 1.0, decimals: 1)}%"
      true -> "<0.1%"
    end
  end

  def prob_str(_), do: nil

  @doc "Signed 1-decimal contribution string (`+9.1` / `-2.3`) for the why-breakdowns (#1076 P1)."
  def signed(c) when is_number(c) and c >= 0,
    do: "+#{:erlang.float_to_binary(c * 1.0, decimals: 1)}"

  def signed(c) when is_number(c), do: :erlang.float_to_binary(c * 1.0, decimals: 1)
  def signed(_), do: "—"

  @doc "TMDb w342 poster URL from a `poster_path` (nil-safe)."
  def poster_url(nil), do: nil
  def poster_url("/" <> _ = path), do: "https://image.tmdb.org/t/p/w342#{path}"
  def poster_url(path), do: "https://image.tmdb.org/t/p/w342/#{path}"
end

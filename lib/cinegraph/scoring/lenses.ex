defmodule Cinegraph.Scoring.Lenses do
  @moduledoc "Single source of truth for the 6 scoring lens names and defaults."

  @lenses ~w(mob critics festival_recognition time_machine auteurs box_office)a

  @default_weights %{
    "mob" => 0.10,
    "critics" => 0.10,
    "festival_recognition" => 0.20,
    "time_machine" => 0.20,
    "auteurs" => 0.20,
    "box_office" => 0.20
  }

  @default_atom_weights %{
    mob: 0.10,
    critics: 0.10,
    festival_recognition: 0.20,
    time_machine: 0.20,
    auteurs: 0.20,
    box_office: 0.20
  }

  @default_missing_data_strategies %{
    "mob" => "neutral",
    "critics" => "neutral",
    "festival_recognition" => "exclude",
    "time_machine" => "neutral",
    "auteurs" => "average",
    "box_office" => "exclude"
  }

  def all, do: @lenses
  def all_strings, do: Enum.map(@lenses, &to_string/1)
  def default_weights, do: @default_weights
  def default_atom_weights, do: @default_atom_weights
  def default_missing_data_strategies, do: @default_missing_data_strategies
end

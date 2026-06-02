defmodule Cinegraph.Predictions.PreRegistration do
  @moduledoc """
  A pre-registered hypothesis for a prediction model (#1036, Integrity Protocol Rule 1):
  recorded BEFORE training so results can't be rationalized after the fact —
  expected top features (with the causal story), expected accuracy range, and the
  failure threshold ("what result would prove the model is NOT working").

  Created/linked in Session 2; the `train`-refuses-without-prereg enforcement is Session 3:
  `Trainer.train(save: true)` requires a prereg, and `failure_threshold` (the minimum
  out-of-sample recall@K below which the model is declared a failure) is now mandatory.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Cinegraph.Repo

  schema "prediction_pre_registrations" do
    field :source_key, :string
    field :expected_top_features, :map, default: %{}
    field :expected_accuracy_range, :map, default: %{}
    field :failure_threshold, :string
    field :notes, :string

    has_many :models, Cinegraph.Predictions.Model, foreign_key: :prereg_id

    timestamps()
  end

  @doc false
  def changeset(prereg, attrs) do
    prereg
    |> cast(attrs, [
      :source_key,
      :expected_top_features,
      :expected_accuracy_range,
      :failure_threshold,
      :notes
    ])
    |> validate_required([
      :source_key,
      :expected_top_features,
      :expected_accuracy_range,
      :failure_threshold
    ])
    |> validate_threshold()
  end

  # A failure_threshold that doesn't parse to a recall@K in [0,1] would make `threshold_value/1`
  # return nil and silently disable the integrity gate — reject it at persistence instead.
  defp validate_threshold(changeset) do
    validate_change(changeset, :failure_threshold, fn :failure_threshold, value ->
      case Float.parse(to_string(value)) do
        {f, ""} when f >= 0.0 and f <= 1.0 -> []
        _ -> [failure_threshold: "must be a recall@K value between 0.0 and 1.0 (e.g. \"0.30\")"]
      end
    end)
  end

  @doc """
  Pre-register a hypothesis BEFORE training. `failure_threshold` is the minimum acceptable
  out-of-sample recall@K (as a string, e.g. `"0.30"`); below it the model is a declared
  failure. Returns `{:ok, prereg}` or `{:error, changeset}`.
  """
  def register(attrs) do
    %__MODULE__{}
    |> changeset(attrs)
    |> Repo.insert()
  end

  @doc "Parse `failure_threshold` to a float (min acceptable recall@K), or nil."
  def threshold_value(%__MODULE__{failure_threshold: nil}), do: nil

  def threshold_value(%__MODULE__{failure_threshold: t}) do
    case Float.parse(t) do
      {f, _} -> f
      :error -> nil
    end
  end
end

defmodule Cinegraph.Predictions.ModelClass do
  @moduledoc """
  The contract every prediction model class implements (#1061 Session 1) so it can be **registered,
  run, stored, and served** through one path — the way `Cinegraph.ApiProcessors.Behaviour` makes
  external data sources pluggable.

  The hinge is `serving_kind/0`:

    * `:weight_map` — the fitted artifact serializes to a `%{feature_code => weight}` map and is
      served by the existing `Cinegraph.Scoring.Bus` `Σ wᵢ·featureᵢ` path with **no new scoring
      code**. Weights stay inspectable, so the honesty/calibration/ablation machinery is untouched.
      `Cinegraph.Predictions.LinearLogReg` is the only weight-map class in Session 1.
    * `:opaque` — the artifact is a serialized blob scored via `score/3`; it forfeits per-feature
      weights and must be disclosed as such. (Arrives in Session 2 / Phase 4, gated on evidence.)

  Adding a class that fits the existing feature matrix is config-only: implement this behaviour and
  append the module to `Application.get_env(:cinegraph, :model_classes)`. Classes needing new
  feature prep, a new dependency, or different scoring semantics are a larger change.
  """

  @typedoc "The in-memory fitted artifact. For weight-map classes this is the weight map itself."
  @type fitted :: term()

  @typedoc "A `Cinegraph.Scoring.Bus` spec — `{granularity, weights, source_key}` for weight-map classes."
  @type spec :: term()

  @doc "Stable token persisted to `model_class` columns and ledger rows (e.g. \"linear_logreg\")."
  @callback key() :: String.t()

  @doc "Human-readable name for reports/UI (e.g. \"Linear (logistic regression)\")."
  @callback label() :: String.t()

  @doc "`:weight_map` (served by the bus) or `:opaque` (served via `score/3`)."
  @callback serving_kind() :: :weight_map | :opaque

  @doc """
  Fit on a feature matrix `x` (rows of floats) with 0/1 labels `y` over the ordered
  `feature_names`. `opts` may carry class-specific knobs (e.g. `:alpha`, `:weight_normalize`).
  Returns `{:ok, fitted}` or `{:error, reason}`.
  """
  @callback fit(x :: [[float()]], y :: [0 | 1], feature_names :: [term()], opts :: keyword()) ::
              {:ok, fitted()} | {:error, term()}

  @doc "Build a bus spec from the fitted artifact, for serving/scoring at the given granularity."
  @callback score(fitted(), granularity :: atom(), source_key :: String.t()) :: spec()

  @doc "JSON-able serialization for persistence (weight map, or an opaque blob)."
  @callback serialize(fitted()) :: map()

  @doc "Inverse of `serialize/1` — rehydrate the fitted artifact from a stored map."
  @callback load(map()) :: fitted()

  @doc "Human-facing explanation: the weight map (weight-map classes) or importances (opaque)."
  @callback explain(fitted()) :: map()
end

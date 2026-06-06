defmodule Cinegraph.Predictions.ModelBundle do
  @moduledoc """
  Dev→prod model promotion (#1043) — export a served model as a small, reviewable, git-trackable
  JSON bundle, and import it idempotently on the other side.

  A trained model is three coupled rows, all kilobytes: the `pre_registration` (FK target),
  the `prediction_models` artifact, and the `movie_lists.active_prediction_model_id` pointer.
  Training is heavy and stays on the Studio; serving is `Σ w·value` and already runs on prod.
  Promotion = move the rows correctly:

    * **Gate 1 — substrate parity.** Weights are meaningless without the feature surface they
      weight. Lens models must match prod's `LensConfig.lens_config_hash/0`; data-point models
      need every weighted code present and `is_available` in prod's catalog. Mismatch ⇒ refuse —
      never silently activate.
    * **Gate 2 — holdout integrity.** `integrity_report` + `holdout_spent_at` are the measurement
      taken at train time under the one-spend rule. They travel **verbatim** and are never
      recomputed — prod must not re-spend or relaunder the number.

  Deliberately manual and one-shot (a deploy-time decision, not a sweeper).
  """

  import Ecto.Query

  alias Cinegraph.Movies.MovieLists
  alias Cinegraph.Metrics
  alias Cinegraph.Predictions.{Model, PreRegistration}
  alias Cinegraph.Repo
  alias Cinegraph.Scoring.{Bus, LensConfig}

  @format_version 1

  @model_fields ~w(source_key feature_set weights weights_hash model_version lens_config_hash
                   backtest_strategy model_class serialized_model metrics calibration
                   integrity_report holdout_spent_at run_id)a

  @prereg_fields ~w(source_key expected_top_features expected_accuracy_range failure_threshold
                    notes)a

  # ── export ─────────────────────────────────────────────────────────────────────────

  @doc "Export the ACTIVE model for `source_key` as a bundle map, or `{:error, :no_active_model}`."
  def export(source_key) when is_binary(source_key) do
    case Bus.active_model(source_key) do
      nil ->
        {:error, :no_active_model}

      model ->
        model = Repo.preload(model, :pre_registration)

        {:ok,
         %{
           "format_version" => @format_version,
           "source_key" => source_key,
           "substrate_fingerprint" => %{
             "lens_config_hash" => LensConfig.lens_config_hash()
           },
           "pre_registration" => take_fields(model.pre_registration, @prereg_fields),
           "model" => take_fields(model, @model_fields),
           "active" => true
         }}
    end
  end

  @doc "Export every served list. Returns `[{source_key, {:ok, bundle} | {:error, _}}]`."
  def export_all do
    MovieLists.all_displayable()
    |> Enum.map(& &1.source_key)
    |> Enum.map(&{&1, export(&1)})
    |> Enum.filter(fn {_sk, result} -> match?({:ok, _}, result) end)
  end

  @doc """
  Write a bundle to `priv/prediction_models/<source_key>-<weights_hash>.json`, deterministically
  encoded (recursively key-sorted) so the artifact is git-diffable. Returns the path.
  """
  def write!(%{"source_key" => sk, "model" => %{"weights_hash" => hash}} = bundle) do
    dir = Path.join([:code.priv_dir(:cinegraph), "prediction_models"])
    File.mkdir_p!(dir)
    path = Path.join(dir, "#{sk}-#{hash}.json")
    File.write!(path, encode_deterministic(bundle))
    path
  end

  @doc "Deterministic (recursively key-sorted) pretty JSON encoding of a bundle."
  def encode_deterministic(bundle) do
    bundle |> sort_keys() |> Jason.encode!(pretty: true)
  end

  # Structs (DateTime etc.) pass through to their own Jason encoders.
  defp sort_keys(%_{} = struct), do: struct

  defp sort_keys(%{} = map) do
    map
    |> Enum.sort_by(fn {k, _v} -> to_string(k) end)
    |> Enum.map(fn {k, v} -> {k, sort_keys(v)} end)
    |> Jason.OrderedObject.new()
  end

  defp sort_keys(list) when is_list(list), do: Enum.map(list, &sort_keys/1)
  defp sort_keys(other), do: other

  # ── import ─────────────────────────────────────────────────────────────────────────

  @doc """
  Idempotent, transactional, FK-ordered import of a bundle. Returns
  `{:ok, %{status: "imported"|"already_present", model_id, weights_hash, activated}}` or
  `{:error, reason}` (incl. `{:substrate_mismatch, details}` from Gate 1 — refused, never
  silently activated).
  """
  def import(bundle, _opts \\ [])

  def import(%{"format_version" => v}, _opts) when v != @format_version,
    do: {:error, {:unknown_format_version, v}}

  def import(%{"format_version" => @format_version} = bundle, _opts) do
    with :ok <- check_substrate_parity(bundle) do
      Repo.transaction(fn ->
        prereg = find_or_create_prereg!(bundle["pre_registration"])
        {status, model} = upsert_model!(bundle["model"], prereg.id)
        activated = maybe_activate(bundle, model)

        %{
          status: status,
          model_id: model.id,
          weights_hash: model.weights_hash,
          activated: activated
        }
      end)
    end
  end

  def import(_bundle, _opts), do: {:error, :malformed_bundle}

  @doc "Decode a base64-encoded JSON bundle and import it — the `ProdRpc.eval_json` entry point."
  def import_base64(b64) when is_binary(b64) do
    with {:ok, json} <- Base.decode64(b64),
         {:ok, bundle} <- Jason.decode(json) do
      __MODULE__.import(bundle)
    else
      :error -> {:error, :invalid_base64}
      {:error, %Jason.DecodeError{}} -> {:error, :invalid_json}
    end
  end

  # ── Gate 1: substrate parity ─────────────────────────────────────────────────────────
  # A weight vector only means what it meant at train time if the feature surface matches.
  defp check_substrate_parity(bundle) do
    model = bundle["model"] || %{}
    granularity = get_in(model, ["feature_set", "granularity"]) || "lens"

    case granularity do
      "data_point" ->
        missing =
          model
          |> Map.get("weights", %{})
          |> Map.keys()
          |> Enum.reject(fn code ->
            match?(%{is_available: true}, Metrics.get_metric_definition(code))
          end)

        if missing == [],
          do: :ok,
          else: {:error, {:substrate_mismatch, {:missing_or_unavailable_codes, missing}}}

      _lens ->
        bundle_hash = get_in(bundle, ["substrate_fingerprint", "lens_config_hash"])
        local_hash = LensConfig.lens_config_hash()

        if bundle_hash == local_hash,
          do: :ok,
          else:
            {:error,
             {:substrate_mismatch, {:lens_config_hash, expected: bundle_hash, got: local_hash}}}
    end
  end

  # ── prereg: find-or-create by content (the FK target must travel with the model) ─────
  defp find_or_create_prereg!(attrs) when is_map(attrs) do
    existing =
      Repo.one(
        from p in PreRegistration,
          where:
            p.source_key == ^attrs["source_key"] and
              p.failure_threshold == ^attrs["failure_threshold"] and
              p.expected_top_features == ^(attrs["expected_top_features"] || %{}) and
              p.expected_accuracy_range == ^(attrs["expected_accuracy_range"] || %{}),
          limit: 1
      )

    case existing do
      %PreRegistration{} = p ->
        p

      nil ->
        case PreRegistration.register(atomize(attrs, @prereg_fields)) do
          {:ok, p} -> p
          {:error, changeset} -> Repo.rollback({:prereg_invalid, changeset.errors})
        end
    end
  end

  defp find_or_create_prereg!(_), do: Repo.rollback(:missing_pre_registration)

  # ── model: upsert on (source_key, weights_hash, model_version); Gate 2 verbatim ──────
  defp upsert_model!(attrs, prereg_id) when is_map(attrs) do
    case Repo.one(
           from m in Model,
             where:
               m.source_key == ^attrs["source_key"] and
                 m.weights_hash == ^attrs["weights_hash"] and
                 m.model_version == ^(attrs["model_version"] || 1),
             limit: 1
         ) do
      %Model{} = m ->
        {"already_present", m}

      nil ->
        # integrity_report + holdout_spent_at pass through VERBATIM — never recomputed here.
        changeset_attrs =
          attrs
          |> atomize(@model_fields)
          |> Map.put(:prereg_id, prereg_id)

        case %Model{} |> Model.changeset(changeset_attrs) |> Repo.insert() do
          {:ok, m} -> {"imported", m}
          {:error, changeset} -> Repo.rollback({:model_invalid, changeset.errors})
        end
    end
  end

  defp upsert_model!(_, _), do: Repo.rollback(:missing_model)

  # ── pointer flip — through the sole guarded write path ───────────────────────────────
  defp maybe_activate(%{"active" => true} = bundle, model) do
    case MovieLists.set_active_prediction_model(bundle["source_key"], model.id, model.weights) do
      {:ok, _list} ->
        true

      # The activation guard refusing (e.g. :insufficient grade) is an HONEST outcome — the
      # rows are imported, the list serves nothing, and the result says so.
      {:error, _reason} ->
        false
    end
  end

  defp maybe_activate(_bundle, _model), do: false

  defp take_fields(struct, fields) do
    struct
    |> Map.take(fields)
    |> Map.new(fn {k, v} -> {to_string(k), v} end)
  end

  defp atomize(string_map, allowed) do
    Map.new(allowed, fn key -> {key, Map.get(string_map, to_string(key))} end)
  end
end

defmodule Mix.Tasks.Predictions.Model.Push do
  @shortdoc "Promote served models to production via ProdRpc (#1043)"

  @moduledoc """
  The Studio-side promotion command. Exports the served model(s) and ships them to production
  through the existing `Cinegraph.ProdRpc` channel (kamal exec — no dev→prod DB coupling).

      mix predictions.model.push --all              # dry-run: what would ship
      mix predictions.model.push --all --check      # READ-ONLY prod substrate preflight (Gate 1)
      mix predictions.model.push --all --commit     # ship + import + activate in prod
      mix predictions.model.push --list 1001_movies --commit

  `--check` uses only modules that already exist in any deployed image (LensConfig + Metrics),
  so it works BEFORE the image containing ModelBundle is deployed. `--commit` requires the
  deployed image to contain `Cinegraph.Predictions.ModelBundle` — if prod raises
  UndefinedFunctionError, deploy first.
  """
  use Mix.Task

  alias Cinegraph.Predictions.ModelBundle
  alias Cinegraph.ProdRpc

  @impl true
  def run(args) do
    Mix.Task.run("app.start")
    Logger.configure(level: :warning)

    {opts, _, _} =
      OptionParser.parse(args,
        strict: [list: :string, all: :boolean, check: :boolean, commit: :boolean]
      )

    bundles = collect_bundles(opts)

    cond do
      opts[:check] -> preflight(bundles)
      opts[:commit] -> push_all(bundles)
      true -> dry_run(bundles)
    end
  end

  defp collect_bundles(opts) do
    raw =
      cond do
        opts[:all] -> ModelBundle.export_all()
        opts[:list] -> [{opts[:list], ModelBundle.export(opts[:list])}]
        true -> Mix.raise("pass --list SOURCE_KEY or --all")
      end

    for {sk, result} <- raw do
      case result do
        {:ok, bundle} -> {sk, bundle}
        {:error, reason} -> Mix.raise("#{sk}: cannot export — #{inspect(reason)}")
      end
    end
  end

  defp dry_run(bundles) do
    Mix.shell().info("\nDry run — would ship #{length(bundles)} bundle(s):\n")

    Enum.each(bundles, fn {sk, bundle} ->
      Mix.shell().info(
        "  #{String.pad_trailing(sk, 26)} #{bundle["model"]["weights_hash"]} " <>
          "(#{bundle["model"]["backtest_strategy"]}, #{map_size(bundle["model"]["weights"])} weights)"
      )
    end)

    Mix.shell().info("\nNext: --check (read-only prod parity) then --commit.")
  end

  # ── Gate 1 preflight against the LIVE prod container — read-only, needs no new prod code ──
  defp preflight(bundles) do
    codes =
      bundles
      |> Enum.flat_map(fn {_sk, b} -> Map.keys(b["model"]["weights"] || %{}) end)
      |> Enum.uniq()
      |> Enum.sort()

    # Raw SQL + schema introspection + rescued lens-hash so the preflight works against ANY
    # deployed image/schema age — today's prod predates both `get_metric_definition/1` and the
    # catalog's `is_available` column. The preflight's job is to SAY that, not crash on it.
    expr = """
    codes = #{inspect(codes)}

    {:ok, %{rows: [[col_count]]}} =
      Cinegraph.Repo.query(
        "SELECT count(*) FROM information_schema.columns " <>
          "WHERE table_name = 'metric_definitions' AND column_name = 'is_available'",
        []
      )

    schema_current = col_count > 0

    sql =
      if schema_current,
        do: "SELECT code FROM metric_definitions WHERE code = ANY($1) AND is_available = true",
        else: "SELECT code FROM metric_definitions WHERE code = ANY($1)"

    {:ok, %{rows: rows}} = Cinegraph.Repo.query(sql, [codes])
    available = Enum.map(rows, fn [c] -> c end)

    lens_hash =
      try do
        Cinegraph.Scoring.LensConfig.lens_config_hash()
      rescue
        _ -> nil
      end

    IO.puts(
      Jason.encode!(%{
        schema_current: schema_current,
        lens_config_hash: lens_hash,
        missing_codes: codes -- available
      })
    )
    """

    Mix.shell().info("\nProd substrate preflight (#{length(codes)} distinct codes)…")

    case ProdRpc.eval_json(expr) do
      {:ok,
       %{
         "schema_current" => schema_current,
         "lens_config_hash" => prod_hash,
         "missing_codes" => missing
       }} ->
        unless schema_current do
          Mix.shell().info(
            "  ⚠ prod schema predates the catalog migrations (`is_available` missing) — " <>
              "code presence checked, availability NOT. Deploy (with migrations) before --commit."
          )
        end

        Enum.each(bundles, fn {sk, bundle} ->
          report_parity(sk, bundle, prod_hash, missing)
        end)

      {:error, reason} ->
        Mix.raise("preflight failed (is kamal configured on this machine?): #{inspect(reason)}")
    end
  end

  defp report_parity(sk, bundle, prod_hash, missing_codes) do
    model = bundle["model"]
    granularity = get_in(model, ["feature_set", "granularity"]) || "lens"

    verdict =
      case granularity do
        "data_point" ->
          mine = model["weights"] |> Map.keys() |> MapSet.new()
          missing = Enum.filter(missing_codes, &MapSet.member?(mine, &1))

          if missing == [],
            do: "✓ all #{MapSet.size(mine)} codes available in prod",
            else: "✗ MISSING in prod catalog: #{Enum.join(missing, ", ")}"

        _lens ->
          bundle_hash = get_in(bundle, ["substrate_fingerprint", "lens_config_hash"])

          cond do
            is_nil(prod_hash) ->
              "? prod image too old to report lens_config_hash — deploy before pushing lens models"

            bundle_hash == prod_hash ->
              "✓ lens_config_hash matches"

            true ->
              "✗ lens_config_hash mismatch (bundle #{bundle_hash}, prod #{prod_hash})"
          end
      end

    Mix.shell().info("  #{String.pad_trailing(sk, 26)} #{verdict}")
  end

  # ── commit: ship each bundle through the eval channel ───────────────────────────────
  defp push_all(bundles) do
    Mix.shell().info("\nPushing #{length(bundles)} bundle(s) to prod…\n")

    Enum.each(bundles, fn {sk, bundle} ->
      b64 = bundle |> ModelBundle.encode_deterministic() |> Base.encode64()

      expr = """
      result =
        case Cinegraph.Predictions.ModelBundle.import_base64("#{b64}") do
          {:ok, r} -> Jason.encode!(%{ok: r})
          {:error, e} -> Jason.encode!(%{error: inspect(e)})
        end

      IO.puts(result)
      """

      case ProdRpc.eval_json(expr) do
        {:ok, %{"ok" => result}} ->
          Mix.shell().info(
            "  #{String.pad_trailing(sk, 26)} #{result["status"]} · model_id #{result["model_id"]} · activated: #{result["activated"]}"
          )

        {:ok, %{"error" => error}} ->
          Mix.shell().info("  #{String.pad_trailing(sk, 26)} REFUSED: #{error}")

        {:error, reason} ->
          hint =
            if reason |> inspect() =~ "UndefinedFunctionError" or inspect(reason) =~ "ModelBundle",
              do: " (prod image predates ModelBundle — deploy first)",
              else: ""

          Mix.shell().info("  #{String.pad_trailing(sk, 26)} FAILED: #{inspect(reason)}#{hint}")
      end
    end)
  end
end

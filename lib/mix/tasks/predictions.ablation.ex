defmodule Mix.Tasks.Predictions.Ablation do
  @moduledoc """
  The objective-vs-canon ablation (#1051 / #1047's "single most valuable experiment").

  For each list, fits the holdout-free sandbox (`Trainer.run_sweep/3`, ranking members against the
  full decade pool #1055) on three feature buckets and reports validation PR-AUC + recall@K + lift
  over the popularity baseline:

    * **objective** — `:objective_only`: ratings, votes, box office, festival, metadata, the derived
      ROI/prestige/collab features. The honest "independent signal" set.
    * **canon** — `:canon_overlap`: ONLY the circular crutch (other lists' membership +
      canonical_contribution + auteur_track_record + list_appearances).
    * **full** — `:all`: objective ∪ canon (the current production surface).

  The decisive comparison is **objective vs full**: if objective ≈ full, the list is predictable from
  independent signal (a better model class can help — Stage B). If objective collapses toward the
  popularity floor while full is high, the accuracy is mostly canon-overlap circularity — no model
  class fixes that, and the honest move is disclosure (Stage 2).

  ## Usage
      mix predictions.ablation
      mix predictions.ablation --source-key tspdt_1000
      mix predictions.ablation --sample 25000      # fast-mode (approx; iterate across all lists quickly)

  Options:
    --source-key   one list (default: all active lists)
    --seed         RNG seed (default 1337)
    --sample       fast-mode non-member pool cap (0 = full pool, the honest default)
    --alpha        L2 regularization strength applied to all three buckets
  """
  use Mix.Task
  import Ecto.Query

  alias Cinegraph.Predictions.Trainer
  alias Cinegraph.Repo

  @shortdoc "Objective-vs-canon-overlap ablation per list (#1051)"

  @buckets [{:objective_only, "objective"}, {:canon_overlap, "canon"}, {:all, "full"}]

  @impl Mix.Task
  def run(args) do
    Cinegraph.Predictions.TaskSupport.start_lean()
    # Many tiny fits in one process → route to BinaryBackend to avoid EXLA's :system_limit.
    Application.put_env(:nx, :default_backend, Nx.BinaryBackend)

    {opts, _, _} =
      OptionParser.parse(args,
        strict: [source_key: :string, seed: :integer, sample: :integer, alpha: :float]
      )

    seed = Keyword.get(opts, :seed, 1337)
    sweep_opts = Keyword.take(opts, [:sample, :alpha])

    lists =
      case Keyword.get(opts, :source_key) do
        nil -> Repo.all(from l in "movie_lists", where: l.active == true, select: l.source_key)
        sk -> [sk]
      end

    sample_note = if opts[:sample], do: " · sample #{opts[:sample]} (fast-mode, approx)", else: ""

    Mix.shell().info(
      "Objective-vs-canon ablation over #{length(lists)} lists (seed #{seed})#{sample_note}\n"
    )

    rows = Enum.map(lists, fn sk -> {sk, eval_list(sk, seed, sweep_opts)} end)

    print_table(rows)
    print_verdicts(rows)
  end

  # %{"objective"|"canon"|"full" => %{pr_auc, recall, pop}} (or %{} if unevaluable).
  defp eval_list(source_key, seed, sweep_opts) do
    variants = Enum.map(@buckets, fn {sel, id} -> [id: id, features: sel] end)

    Trainer.run_sweep(
      source_key,
      variants,
      Keyword.merge([seed: seed, max_concurrency: 3], sweep_opts)
    )
    |> Map.new(fn r ->
      {r.variant[:id],
       %{
         pr_auc: r.metrics["pr_auc"],
         recall: r.metrics["recall_at_k"],
         pop: get_in(r.metrics, ["baselines", "popularity"])
       }}
    end)
  end

  defp print_table(rows) do
    Mix.shell().info("PR-AUC  |  recall@K  (vs popularity baseline)")
    Mix.shell().info(String.duplicate("-", 96))

    Mix.shell().info(
      "#{String.pad_trailing("list", 28)}#{p("obj pr")}#{p("canon pr")}#{p("full pr")}   |#{p("obj rec")}#{p("canon rec")}#{p("full rec")}#{p("pop")}"
    )

    Mix.shell().info(String.duplicate("-", 96))

    Enum.each(rows, fn {sk, m} ->
      if m == %{} do
        Mix.shell().info("#{String.pad_trailing(sk, 28)}  (unevaluable)")
      else
        o = m["objective"] || %{}
        c = m["canon"] || %{}
        f = m["full"] || %{}

        Mix.shell().info(
          "#{String.pad_trailing(sk, 28)}" <>
            "#{n(o[:pr_auc])}#{n(c[:pr_auc])}#{n(f[:pr_auc])}   |" <>
            "#{n(o[:recall])}#{n(c[:recall])}#{n(f[:recall])}#{n(f[:pop])}"
        )
      end
    end)

    Mix.shell().info("")
  end

  # Per-list verdict from recall@K across the three buckets, answering three questions:
  #   1. independent signal?  objective recall vs the popularity floor
  #   2. canon dominance?     canon recall vs objective recall
  #   3. can the LINEAR model combine them?  full recall vs canon recall (full < canon ⇒ the model
  #      degrades when given more features = regularization/model-class headroom, i.e. Stage B)
  defp print_verdicts(rows) do
    Mix.shell().info("Verdict (recall@K; independent-signal? · combine?):")

    Enum.each(rows, fn {sk, m} ->
      o = get_in(m, ["objective", :recall])
      c = get_in(m, ["canon", :recall])
      f = get_in(m, ["full", :recall])
      pop = get_in(m, ["full", :pop])

      if is_number(o) and is_number(c) and is_number(f) do
        independent =
          cond do
            is_number(pop) and pop > 0 and o >= pop * 1.5 ->
              "independent signal ✓ (#{ratio(o, pop)}× pop)"

            is_number(pop) and o > pop ->
              "weak independent signal"

            true ->
              "no independent signal (≈ popularity)"
          end

        combine =
          cond do
            f < c - 0.05 -> "⚠ full < canon — linear model DILUTES (Stage B headroom)"
            f >= c -> "linear combines cleanly"
            true -> "≈ canon"
          end

        Mix.shell().info(
          "  #{String.pad_trailing(sk, 28)} obj=#{r4(o)} canon=#{r4(c)} full=#{r4(f)} pop=#{r4(pop)} — #{independent}; #{combine}"
        )
      else
        Mix.shell().info("  #{String.pad_trailing(sk, 28)} (unevaluable)")
      end
    end)

    Mix.shell().info("")
  end

  defp ratio(_a, b) when b in [nil, 0, 0.0], do: "∞"
  defp ratio(a, b), do: Float.round(a / b, 1)
  defp r4(nil), do: "—"
  defp r4(v) when is_number(v), do: Float.round(v / 1, 4)

  defp p(s), do: String.pad_leading(s, 10)
  defp n(nil), do: String.pad_leading("—", 10)
  defp n(v) when is_number(v), do: String.pad_leading(Float.to_string(Float.round(v / 1, 4)), 10)
end

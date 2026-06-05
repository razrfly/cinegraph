defmodule Mix.Tasks.Predictions.BuildTextVocab do
  @moduledoc """
  Precompute the plot-overview TF-IDF vocabulary for Lever E (#1070).

  Scans `movies.overview` over all canonical members + a random pool sample, selects the top-N terms
  by document frequency, computes IDF, and writes `priv/scoring/text_vocab.json` (the fixed vocab the
  `Cinegraph.Scoring.TextFeatures` data-point codes `txt_NNN` use). Run once; re-run if the corpus
  changes materially. Building over members + a representative pool keeps the IDF honest for both.

  ## Usage
      mix predictions.build_text_vocab            # members + 40k pool sample (default)
      mix predictions.build_text_vocab --sample 80000
  """
  use Mix.Task
  import Ecto.Query

  alias Cinegraph.Repo
  alias Cinegraph.Scoring.TextFeatures

  @shortdoc "Precompute the overview TF-IDF vocab for Lever E (#1070)"

  @impl Mix.Task
  def run(args) do
    Cinegraph.Predictions.TaskSupport.start_lean()
    Logger.configure(level: :warning)
    {opts, _, _} = OptionParser.parse(args, strict: [sample: :integer])
    sample = Keyword.get(opts, :sample, 40_000)

    members =
      Repo.all(
        from m in "movies",
          where: fragment("? <> '{}'::jsonb", m.canonical_sources) and not is_nil(m.overview),
          select: m.overview
      )

    pool =
      Repo.all(
        from m in "movies",
          where:
            m.import_status == "full" and m.canonical_sources == fragment("'{}'::jsonb") and
              not is_nil(m.overview),
          order_by: fragment("md5(?::text)", m.id),
          select: m.overview,
          limit: ^sample
      )

    corpus = members ++ pool

    Mix.shell().info(
      "Building vocab from #{length(members)} member + #{length(pool)} pool overviews …"
    )

    {path, k} = TextFeatures.build_vocab(corpus)

    Mix.shell().info("Wrote IDF for #{k} terms (#{TextFeatures.dim()} hash buckets) → #{path}")
  end
end

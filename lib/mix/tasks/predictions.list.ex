defmodule Mix.Tasks.Predictions.List do
  @moduledoc """
  One-line-per-list overview of every displayable list and its served prediction model — the
  CLI-parity twin of the `/algorithms` index (#1038). Pure read of
  `MovieLists.list_with_model_stats/0`.

      mix predictions.list
      mix predictions.list --json
  """
  use Mix.Task

  alias Cinegraph.Movies.MovieLists

  @shortdoc "Per-list overview: members, served model, honest reliability grade"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")
    # Quiet dev's :debug Ecto query logging so the table (or --json) is the output.
    Logger.configure(level: :warning)
    {opts, _, _} = OptionParser.parse(args, strict: [json: :boolean])

    stats = MovieLists.list_with_model_stats()

    if opts[:json] do
      IO.puts(Jason.encode!(Enum.map(stats, &row_json/1), pretty: true))
    else
      print(stats)
    end
  end

  defp row_json(%{list: list} = s) do
    %{
      source_key: list.source_key,
      name: list.name,
      slug: list.slug,
      members: s.member_count,
      model_id: s.model && s.model.id,
      model_class: s.model && s.model.model_class,
      strategy: s.model && s.model.backtest_strategy,
      grade: s.reliability && to_string(s.reliability.grade),
      headline_pct: s.reliability && s.reliability.headline_pct
    }
  end

  defp print(stats) do
    Mix.shell().info(
      "\n#{pad("list", 28)}#{pad("members", 9)}#{pad("model", 30)}#{pad("grade", 8)}headline"
    )

    Mix.shell().info(String.duplicate("-", 86))

    Enum.each(stats, fn %{list: list} = s ->
      {model_col, grade_col, headline_col} =
        case s.model do
          nil ->
            {"— no active model", "—", "—"}

          model ->
            {
              "##{model.id} #{model.model_class}/#{model.backtest_strategy}",
              s.reliability.grade |> to_string() |> String.upcase(),
              "#{s.reliability.headline_pct}%"
            }
        end

      Mix.shell().info(
        "#{pad(list.source_key, 28)}#{pad(s.member_count, 9)}#{pad(model_col, 30)}#{pad(grade_col, 8)}#{headline_col}"
      )
    end)

    Mix.shell().info(
      "\nLists with no active model are honestly 'not metadata-predictable' (#1070).\n"
    )
  end

  defp pad(v, n), do: v |> to_string() |> String.pad_trailing(n)
end

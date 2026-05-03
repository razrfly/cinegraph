defmodule Mix.Tasks.Cinegraph.Audit.ImdbListPagination do
  @moduledoc """
  Audit IMDb list pagination windows without mutating importer data.

  ## Usage

      mix cinegraph.audit.imdb_list_pagination --list cult_movies_400
      mix cinegraph.audit.imdb_list_pagination --list-id ls053182933 --starts 1,76,151 --json
  """
  use Mix.Task

  alias Cinegraph.Health.ImdbListPaginationAudit

  @shortdoc "Audit rendered IMDb list pagination windows"

  @doc false
  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, invalid} = parse_args(args)
    raise_invalid_options!(invalid)

    audit_opts = audit_opts(opts)
    result = ImdbListPaginationAudit.audit(audit_opts)

    if Keyword.get(opts, :json, false) do
      result |> Jason.encode!(pretty: true) |> IO.puts()
    else
      print_table(result)
    end
  end

  @doc false
  def parse_args(args) do
    OptionParser.parse(args,
      strict: [
        list: :string,
        list_id: :string,
        "list-id": :string,
        starts: :string,
        page_wait: :integer,
        "page-wait": :integer,
        ajax_wait: :boolean,
        "ajax-wait": :boolean,
        scroll: :boolean,
        scroll_interval: :integer,
        "scroll-interval": :integer,
        json: :boolean
      ]
    )
  end

  @doc false
  def audit_opts(opts) do
    opts
    |> normalize_alias(:"list-id", :list_id)
    |> normalize_alias(:"page-wait", :page_wait)
    |> normalize_alias(:"ajax-wait", :ajax_wait)
    |> normalize_alias(:"scroll-interval", :scroll_interval)
    |> Keyword.take([:list, :list_id, :starts, :page_wait, :ajax_wait, :scroll, :scroll_interval])
  end

  defp print_table(%{
         generated_at: at,
         list_key: list_key,
         list_id: list_id,
         summary: summary,
         windows: windows
       }) do
    Mix.shell().info("IMDb list pagination audit - generated #{at}")
    Mix.shell().info("list=#{list_key || "-"} list_id=#{list_id}")

    Mix.shell().info(
      "unique=#{summary.total_unique_ids} safe=#{summary.safe_to_import} gaps=#{summary.has_gaps} duplicates=#{summary.has_duplicates} page_size=#{summary.recommended_page_size || "-"} strategy=#{summary.recommended_url_strategy}"
    )

    Mix.shell().info("")

    Mix.shell().info(
      String.pad_leading("start", 7) <>
        String.pad_leading("count", 7) <>
        String.pad_leading("first", 8) <>
        String.pad_leading("last", 8) <>
        String.pad_leading("gap", 6) <>
        "  " <>
        String.pad_trailing("status", 8) <>
        String.pad_trailing("layout", 14) <>
        "sample"
    )

    Mix.shell().info(String.duplicate("-", 100))

    Enum.each(windows, fn window ->
      sample = Enum.join(window.sample_titles, " | ")

      Mix.shell().info(
        String.pad_leading(to_string(window.start), 7) <>
          String.pad_leading(to_string(window.movie_count), 7) <>
          String.pad_leading(to_string(window.first_rank || "-"), 8) <>
          String.pad_leading(to_string(window.last_rank || "-"), 8) <>
          String.pad_leading(to_string(window.rank_gap_from_previous || "-"), 6) <>
          "  " <>
          String.pad_trailing(window.fetch_status, 8) <>
          String.pad_trailing(window.parser_layout, 14) <>
          sample
      )
    end)
  end

  defp normalize_alias(opts, from, to) do
    case Keyword.pop(opts, from) do
      {nil, opts} -> opts
      {value, opts} -> Keyword.put(opts, to, value)
    end
  end

  defp raise_invalid_options!([]), do: :ok
  defp raise_invalid_options!(invalid), do: Mix.raise("invalid option(s): #{inspect(invalid)}")
end

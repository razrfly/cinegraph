defmodule Mix.Tasks.Cinegraph.Audit.ImdbEventId do
  @moduledoc """
  Live IMDb event-ID inspector. Disambiguates failure labels from the
  year-discovery audit by hitting IMDb directly.

  This is the documented exception to the pure-DB audit rule (#766) — it
  calls IMDb live via `Cinegraph.Scrapers.Http.Client`. Use it to figure
  out *why* a festival is labeled `:source_unavailable` or
  `:parser_breakage` in `mix cinegraph.audit.year_discovery`.

  No prod variant — the tool reads from IMDb, not the DB. Run from any
  dev machine with internet access (and Crawlbase credentials if your
  `:scraping_strategies` config routes IMDb through Crawlbase).

  ## Usage

      mix cinegraph.audit.imdb_event_id ev0000147             # Cannes
      mix cinegraph.audit.imdb_event_id ev0000400 --json      # Locarno, JSON
      mix cinegraph.audit.imdb_event_id ev0000484 --year 2025
  """
  use Mix.Task

  alias Cinegraph.Health.ImdbEventInspector

  @shortdoc "Live-inspect what IMDb returns for an event ID"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, positional, invalid} =
      OptionParser.parse(args, strict: [json: :boolean, year: :integer])

    raise_invalid_options!(invalid)

    event_id =
      case positional do
        [id] when is_binary(id) ->
          id

        _ ->
          Mix.raise("usage: mix cinegraph.audit.imdb_event_id <event_id> [--year YYYY] [--json]")
      end

    inspector_opts = if opts[:year], do: [year: opts[:year]], else: []
    result = ImdbEventInspector.inspect(event_id, inspector_opts)

    if Keyword.get(opts, :json, false) do
      result
      |> Jason.encode!(pretty: true)
      |> IO.puts()
    else
      print_summary(result)
    end
  end

  defp raise_invalid_options!([]), do: :ok

  defp raise_invalid_options!(invalid) do
    Mix.raise("invalid option(s): #{inspect(invalid)}")
  end

  defp print_summary(%{event_id: ev, url: url} = r) do
    Mix.shell().info("Event: #{ev}")
    Mix.shell().info("URL:   #{url}")

    case r.fetch_status do
      :ok ->
        Mix.shell().info("Fetch: ok (#{r.bytes} bytes)")

      %{error: reason} ->
        Mix.shell().info("Fetch: error — #{reason}")
    end

    Mix.shell().info("Parser status: #{r.parser_status}")
    Mix.shell().info("__NEXT_DATA__: #{if r.has_next_data, do: "present", else: "MISSING"}")
    Mix.shell().info("editions_count: #{r.editions_count}")

    Mix.shell().info(
      "years_with_data: count=#{r.years_with_data.count} sample=#{inspect(r.years_with_data.sample)}"
    )

    Mix.shell().info("event_name: #{inspect(r.event_name)}")
    Mix.shell().info("")
    Mix.shell().info("Suggested label: #{r.suggested_label}")
    Mix.shell().info(label_explanation(r.suggested_label))
  end

  defp label_explanation(:ok),
    do: "  → IMDb returns valid editions data. Year-discovery should succeed."

  defp label_explanation(:bad_event_id),
    do:
      "  → IMDb returned 404 (or fetch failure suggesting the ID is wrong). Update festival_events.imdb_event_id."

  defp label_explanation(:source_unavailable),
    do:
      "  → IMDb returns the page but historyEventEditions is empty. The event genuinely lacks editions data on IMDb (or the ID redirects to a generic page — check event_name). Likely fix: discovery_disabled flag on the festival."

  defp label_explanation(:parser_breakage),
    do:
      "  → IMDb returns something the parser can't handle (no __NEXT_DATA__ tag, malformed JSON, or unexpected shape). Likely fix: switch year discovery to direct fetch (Crawlbase may be returning a stale snapshot), or update the parser."
end

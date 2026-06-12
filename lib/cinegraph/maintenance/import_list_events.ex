defmodule Cinegraph.Maintenance.ImportListEvents do
  @moduledoc """
  Release-safe entry point for importing list-membership add/remove events (#1115).

  Layer 1 of the house maintenance/sweeper pattern (cf.
  `Cinegraph.Maintenance.RefreshCanonicalLists`): pure logic, callable from the
  `import_list_events` mix task or `iex`. For each in-scope canonical list it
  scrapes addition/removal events, resolves each scraped entry to a movie
  (`MovieMatcher`), and bulk-upserts into `list_membership_events` — matched rows
  carry a `movie_id`, unmatched rows are kept as `pending` (never dropped).

  Idempotent and resumable: `ListMembershipEvents.upsert_events/1` dedups against
  the two partial unique indexes, so re-running re-upserts the same facts with no
  row growth.

  Session-1 scope is NFR + 1001 (the two crown-jewel sources); the dispatcher
  accepts further sources without other changes.
  """

  require Logger

  alias Cinegraph.ListEvents.{ListMembershipEvents, MovieMatcher}
  alias Cinegraph.Scrapers.{Movies1001Scraper, NfrScraper}

  @scrapers %{
    "national_film_registry" => NfrScraper,
    "1001_movies" => Movies1001Scraper
  }

  @doc "Source keys this importer can populate, in priority order."
  def sources, do: ["national_film_registry", "1001_movies"]

  @doc """
  Import events for one or all in-scope sources.

  Options (exactly one selector required):
    * `:source` — a single source_key
    * `:all` — every source in `sources/0`
    * `:dry_run` — scrape + match + report, but do not write (default false)
    * `:rematch_pending` — re-run the matcher over existing pending rows and
      promote those that now resolve (runs in addition to / instead of scraping)
  """
  def run(opts \\ []) when is_list(opts) do
    cond do
      Keyword.get(opts, :rematch_pending, false) ->
        {:ok, rematch_pending(opts)}

      true ->
        validate_selector!(opts)
        dry_run? = Keyword.get(opts, :dry_run, false)
        results = Enum.map(select_sources(opts), &import_source(&1, dry_run?))
        {:ok, %{sources: results, dry_run: dry_run?}}
    end
  end

  defp validate_selector!(opts) do
    selected = Enum.count([:source, :all], &(Keyword.get(opts, &1) not in [nil, false]))

    if selected == 1 do
      :ok
    else
      raise ArgumentError, "provide exactly one selector: :source or :all"
    end
  end

  defp select_sources(opts) do
    cond do
      key = Keyword.get(opts, :source) -> [key]
      Keyword.get(opts, :all, false) -> sources()
    end
  end

  defp import_source(source_key, dry_run?) do
    case Map.fetch(@scrapers, source_key) do
      :error ->
        %{source_key: source_key, error: :unknown_source}

      {:ok, scraper} ->
        case scraper.scrape() do
          {:ok, events, %{coverage: coverage}} ->
            resolved = Enum.map(events, &resolve_match(&1, source_key))

            upsert =
              if dry_run? do
                %{inserted: 0, matched: 0, pending: 0}
              else
                resolved |> Enum.map(& &1.row) |> ListMembershipEvents.upsert_events()
              end

            %{
              source_key: source_key,
              found: length(events),
              matched: Enum.count(resolved, &(&1.row.match_state == "matched")),
              pending: Enum.count(resolved, &(&1.row.match_state == "pending")),
              upserted: upsert.inserted,
              coverage: coverage,
              reconciliation: reconcile_or_nil(source_key, dry_run?),
              dry_run: dry_run?
            }

          {:error, reason} ->
            Logger.error("ImportListEvents: #{source_key} scrape failed: #{inspect(reason)}")
            %{source_key: source_key, error: reason}
        end
    end
  end

  defp reconcile_or_nil(_source_key, true), do: nil
  defp reconcile_or_nil(source_key, false), do: ListMembershipEvents.reconcile(source_key)

  # Resolve one scraped event to a matched or pending row map for upsert.
  defp resolve_match(event, source_key) do
    matcher_input = %{
      raw_imdb_id: event.raw_imdb_id,
      raw_title: event.raw_title,
      raw_year: event.raw_year
    }

    base = %{
      source_key: source_key,
      event_type: event.event_type,
      event_edition: event.event_edition,
      event_date: event.event_date,
      raw_title: event.raw_title,
      raw_year: event.raw_year,
      raw_imdb_id: event.raw_imdb_id,
      source_url: event.source_url
    }

    row =
      case MovieMatcher.match(matcher_input) do
        {:ok, movie, method} ->
          base
          |> Map.put(:movie_id, movie.id)
          |> Map.put(:match_state, "matched")
          |> Map.put(:provenance, Map.put(event.provenance, "match_method", to_string(method)))

        :no_match ->
          base
          |> Map.put(:movie_id, nil)
          |> Map.put(:match_state, "pending")
          |> Map.put(:provenance, Map.put(event.provenance, "pending_reason", "no_match"))

        :ambiguous ->
          base
          |> Map.put(:movie_id, nil)
          |> Map.put(:match_state, "pending")
          |> Map.put(:provenance, Map.put(event.provenance, "pending_reason", "ambiguous"))
      end

    %{row: row}
  end

  # ── Pending re-match sweep ────────────────────────────────────────────────

  defp rematch_pending(opts) do
    source_key = Keyword.get(opts, :source)
    pending = ListMembershipEvents.list_pending(source_key)

    {promoted, still_pending} =
      Enum.reduce(pending, {0, 0}, fn event, {promoted, still} ->
        input = %{
          raw_imdb_id: event.raw_imdb_id,
          raw_title: event.raw_title,
          raw_year: event.raw_year
        }

        case MovieMatcher.match(input) do
          {:ok, movie, _method} ->
            ListMembershipEvents.promote_pending(event.id, movie.id)
            {promoted + 1, still}

          _ ->
            {promoted, still + 1}
        end
      end)

    %{
      rematch_pending: true,
      examined: length(pending),
      promoted: promoted,
      still_pending: still_pending
    }
  end
end

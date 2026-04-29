#!/usr/bin/env elixir
# Search Load Script — measures Cinegraph.Search.global/2 against the live DB.
#
# Usage: mix run priv/scripts/search_load.exs
#
# Issues ~200 representative queries against the global typeahead, captures
# per-group + global timings via :telemetry, and prints p50/p95/p99 plus the
# baseline row counts of the four searched tables. Exits non-zero if the
# documented targets are missed:
#
#   • global p95   ≤ 100 ms
#   • per-group p95 ≤ 25 ms (films / people / lists / companies)

alias Cinegraph.Repo
alias Cinegraph.Movies.{Movie, MovieList, Person, ProductionCompany}

defmodule SearchLoad do
  @global_p95_target_ms 100
  @group_p95_target_ms 25

  @prefix_seeds ~w(
    the and god kar wong scor war wong kar-wai criterion fox warner sony netflix
    a24 universal columbia paramount disney pixar miyazaki kurosawa kubrick
    spielberg coppola scorsese tarantino lynch wenders almodovar
    casablanca mulholland persona stalker amadeus alien aliens
    the godfather the matrix the dark knight pulp fiction citizen kane
    forrest gump fight club inception interstellar parasite
  )

  @typo_seeds ~w(
    godfath spielbg kurawasa scrocese mialki tarantno lych alfre hitkock
    kobrick pixr disnee criterino warnr foxs
  )

  def main do
    print_header()
    queries = build_queries()

    # Drop any cache state so first-touch latencies are measured.
    Cachex.clear(:movies_cache)

    {global_samples, group_samples} = collect_samples(queries)

    IO.puts("\n--- timings (ms) over #{length(queries)} queries ---")
    print_table("global", global_samples)

    Enum.each([:films, :people, :lists, :companies], fn g ->
      print_table("group: #{g}", Map.get(group_samples, g, []))
    end)

    failures = check_targets(global_samples, group_samples)

    if failures == [] do
      IO.puts("\n✓ all targets met")
      :erlang.halt(0)
    else
      IO.puts("\n✗ TARGETS MISSED:")
      Enum.each(failures, fn msg -> IO.puts("  - #{msg}") end)
      :erlang.halt(1)
    end
  end

  defp print_header do
    counts = %{
      movies: Repo.aggregate(Movie, :count, :id),
      people: Repo.aggregate(Person, :count, :id),
      movie_lists: Repo.aggregate(MovieList, :count, :id),
      production_companies: Repo.aggregate(ProductionCompany, :count, :id)
    }

    IO.puts("Cinegraph.Search.global/2 load test")
    IO.puts("Dataset:")

    Enum.each(counts, fn {table, n} ->
      IO.puts("  #{table}: #{format_int(n)}")
    end)

    IO.puts("Targets:")
    IO.puts("  global p95 ≤ #{@global_p95_target_ms}ms")
    IO.puts("  per-group p95 ≤ #{@group_p95_target_ms}ms")
  end

  defp build_queries do
    # Build a representative mix of: prefix hits, trigram fallbacks (typos),
    # very short queries (rejected sub-threshold), and progressive prefixes
    # (typing simulation).

    sub_threshold = ~w(a t z 1)

    progressive =
      Enum.flat_map(["the godfather", "wong kar-wai", "scorsese"], fn term ->
        for n <- 2..String.length(term)//1, do: String.slice(term, 0, n)
      end)

    base = @prefix_seeds ++ @typo_seeds ++ progressive ++ sub_threshold

    # Pad to ~200 queries by repeating with shuffles to mimic cache thrash.
    base
    |> List.duplicate(div(200, length(base)) + 1)
    |> List.flatten()
    |> Enum.take(200)
    |> Enum.shuffle()
  end

  defp collect_samples(queries) do
    test_pid = self()
    handler_id = "search-load-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      handler_id,
      [
        [:cinegraph, :search, :global],
        [:cinegraph, :search, :group]
      ],
      fn name, %{duration_ms: ms}, meta, _ ->
        send(test_pid, {:tele, name, ms, meta})
      end,
      nil
    )

    Enum.each(queries, fn q ->
      _ = Cinegraph.Search.global(q)
    end)

    # Drain mailbox.
    {globals, groups} = drain([], %{}, _budget = 5_000)

    :telemetry.detach(handler_id)
    {globals, groups}
  end

  defp drain(globals, groups, budget) do
    receive do
      {:tele, [:cinegraph, :search, :global], ms, _meta} ->
        drain([ms | globals], groups, budget)

      {:tele, [:cinegraph, :search, :group], ms, %{group: g}} ->
        drain(globals, Map.update(groups, g, [ms], &[ms | &1]), budget)
    after
      budget -> {globals, groups}
    end
  end

  defp print_table(label, []) do
    IO.puts(String.pad_trailing(label, 20) <> "  (no samples)")
  end

  defp print_table(label, samples) do
    sorted = Enum.sort(samples)
    n = length(sorted)
    p50 = percentile(sorted, n, 0.50)
    p95 = percentile(sorted, n, 0.95)
    p99 = percentile(sorted, n, 0.99)
    max = List.last(sorted)

    IO.puts(
      String.pad_trailing(label, 20) <>
        "  n=#{String.pad_leading(Integer.to_string(n), 4)}" <>
        "  p50=#{fmt(p50)}  p95=#{fmt(p95)}  p99=#{fmt(p99)}  max=#{fmt(max)}"
    )
  end

  defp percentile(sorted, n, q) do
    idx = max(0, min(n - 1, round(q * (n - 1))))
    Enum.at(sorted, idx)
  end

  defp fmt(nil), do: "  -  "
  defp fmt(ms) when is_float(ms), do: :io_lib.format("~6.1fms", [ms]) |> IO.iodata_to_binary()
  defp fmt(ms), do: "#{ms}ms"

  defp check_targets(global_samples, group_samples) do
    failures = []

    failures =
      case global_samples do
        [] -> ["no global samples captured" | failures]
        _ -> assert_p95("global", global_samples, @global_p95_target_ms, failures)
      end

    Enum.reduce([:films, :people, :lists, :companies], failures, fn g, acc ->
      assert_p95("group #{g}", Map.get(group_samples, g, []), @group_p95_target_ms, acc)
    end)
  end

  defp assert_p95(_label, [], _target, acc), do: acc

  defp assert_p95(label, samples, target_ms, acc) do
    sorted = Enum.sort(samples)
    p95 = percentile(sorted, length(sorted), 0.95)

    if p95 <= target_ms do
      acc
    else
      ["#{label} p95=#{fmt(p95)} exceeds target of #{target_ms}ms" | acc]
    end
  end

  defp format_int(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.codepoints()
    |> Enum.chunk_every(3)
    |> Enum.map_join(",", &Enum.join/1)
    |> String.reverse()
  end
end

SearchLoad.main()

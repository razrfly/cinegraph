defmodule Mix.Tasks.Cinegraph.Drift do
  @moduledoc """
  Drift checks per domain.

  ## Usage

      mix cinegraph.drift people [--json] [--limit N]
      mix cinegraph.drift movies [--json] [--year YYYY]   (PR 4)
      mix cinegraph.drift festivals [--json] [--org SLUG] (PR 4)
      mix cinegraph.drift ratings [--json]                (PR 4)

  ## Options

    * `--json`  — emit JSON matching the `Cinegraph.Health.Drift` contract
    * `--limit` — examples per check (default 10)
  """
  use Mix.Task

  @shortdoc "Run drift checks for a given domain"

  @impl Mix.Task
  def run([]), do: usage_error("missing domain")

  def run([domain | rest]) do
    Mix.Task.run("app.start")

    {opts, _, invalid} =
      OptionParser.parse(rest,
        strict: [json: :boolean, limit: :integer, year: :integer, org: :string]
      )

    reject_invalid_switches!(invalid)

    json? = Keyword.get(opts, :json, false)

    # Strip flags that aren't drift-module options
    runner_opts = Keyword.drop(opts, [:json])

    case domain do
      "people" ->
        runner_opts |> validate_opts!(:people) |> run_people(json?)

      "movies" ->
        runner_opts |> validate_opts!(:movies) |> run_movies(json?)

      "festivals" ->
        runner_opts |> validate_opts!(:festivals) |> run_festivals(json?)

      "ratings" ->
        runner_opts |> validate_opts!(:ratings) |> run_ratings(json?)

      other ->
        usage_error("unknown domain '#{other}' — try people|movies|festivals|ratings")
    end
  end

  defp reject_invalid_switches!([]), do: :ok

  defp reject_invalid_switches!(invalid) do
    flags = invalid |> Enum.map(fn {flag, _} -> flag end) |> Enum.join(", ")
    usage_error("unknown flag(s): #{flags}")
  end

  # Per-domain option whitelists. `--limit` is universal; `--year` is movies-only;
  # `--org` is festivals-only. Reject unknown flags up front so users aren't
  # silently surprised by ignored options.
  @domain_options %{
    people: [:limit],
    movies: [:limit, :year],
    festivals: [:limit, :org],
    ratings: [:limit]
  }

  defp validate_opts!(opts, domain) do
    allowed = Map.fetch!(@domain_options, domain)
    unknown = Keyword.keys(opts) -- allowed

    case unknown do
      [] ->
        opts

      keys ->
        flags = keys |> Enum.map(&"--#{&1}") |> Enum.join(", ")
        allowed_flags = allowed |> Enum.map(&"--#{&1}") |> Enum.join(", ")

        usage_error("domain '#{domain}' does not support #{flags}; allowed: #{allowed_flags}")
    end
  end

  defp run_people(opts, json?),
    do: run_domain(:people, &Cinegraph.Health.Drift.People.all/1, opts, json?)

  defp run_movies(opts, json?),
    do: run_domain(:movies, &Cinegraph.Health.Drift.Movies.all/1, opts, json?)

  defp run_festivals(opts, json?),
    do: run_domain(:festivals, &Cinegraph.Health.Drift.Festivals.all/1, opts, json?)

  defp run_ratings(opts, json?),
    do: run_domain(:ratings, &Cinegraph.Health.Drift.Ratings.all/1, opts, json?)

  defp run_domain(domain, runner, opts, json?) do
    results = runner.(opts)

    if json? do
      results
      |> Enum.map(&serialize/1)
      |> Jason.encode!(pretty: true)
      |> IO.puts()
    else
      print_table(domain, results)
    end
  end

  defp serialize(result) do
    result
    |> Map.put(:generated_at, DateTime.to_iso8601(result.generated_at))
    |> Map.update!(:examples, fn examples ->
      Enum.map(examples, &serialize_example/1)
    end)
    |> stringify_keys()
  end

  defp serialize_example(example) when is_map(example) do
    Map.new(example, fn
      {k, %DateTime{} = v} -> {to_string(k), DateTime.to_iso8601(v)}
      {k, %Date{} = v} -> {to_string(k), Date.to_iso8601(v)}
      {k, %NaiveDateTime{} = v} -> {to_string(k), NaiveDateTime.to_iso8601(v)}
      {k, v} -> {to_string(k), v}
    end)
  end

  defp stringify_keys(map) when is_map(map) and not is_struct(map) do
    Map.new(map, fn
      {k, nil} -> {to_string(k), nil}
      {k, true} -> {to_string(k), true}
      {k, false} -> {to_string(k), false}
      {k, v} when is_atom(v) -> {to_string(k), Atom.to_string(v)}
      {k, v} when is_map(v) -> {to_string(k), stringify_keys(v)}
      {k, v} when is_list(v) -> {to_string(k), v}
      {k, v} -> {to_string(k), v}
    end)
  end

  defp print_table(domain, results) do
    Mix.shell().info("Drift checks — domain: #{domain}")
    Mix.shell().info(String.duplicate("=", 110))

    Mix.shell().info(
      String.pad_trailing("check", 44) <>
        String.pad_leading("total", 12) <>
        String.pad_leading("affected", 12) <>
        String.pad_leading("pct", 9) <>
        "  status / blocked"
    )

    Mix.shell().info(String.duplicate("-", 110))

    Enum.each(results, fn r ->
      status_text =
        if r.blocked_reason do
          "BLOCKED: #{r.blocked_reason}"
        else
          Atom.to_string(r.status)
        end

      Mix.shell().info(
        String.pad_trailing(Atom.to_string(r.check), 44) <>
          String.pad_leading(format_int(r.total_population), 12) <>
          String.pad_leading(format_int(r.affected_count), 12) <>
          String.pad_leading("#{r.affected_pct}%", 9) <>
          "  " <> status_text
      )
    end)

    Mix.shell().info(String.duplicate("=", 110))
    Mix.shell().info("(status is :unknown until Verdict ships in #722 PR 5)")
  end

  defp format_int(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.graphemes()
    |> Enum.reverse()
    |> Enum.chunk_every(3)
    |> Enum.intersperse(",")
    |> List.flatten()
    |> Enum.reverse()
    |> Enum.join()
  end

  defp format_int(other), do: inspect(other)

  defp usage_error(msg) do
    Mix.shell().error("✗ #{msg}")
    Mix.shell().info("\nUsage:")
    Mix.shell().info("  mix cinegraph.drift people    [--json] [--limit N]")
    Mix.shell().info("  mix cinegraph.drift movies    [--json] [--limit N] [--year YYYY]")
    Mix.shell().info("  mix cinegraph.drift festivals [--json] [--limit N] [--org SLUG]")
    Mix.shell().info("  mix cinegraph.drift ratings   [--json] [--limit N]")
    System.halt(1)
  end
end

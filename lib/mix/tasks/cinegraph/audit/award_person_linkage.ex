defmodule Mix.Tasks.Cinegraph.Audit.AwardPersonLinkage do
  @moduledoc """
  Audit festival nomination person-award linkage drift (#873).

  Classifies `festival_nominations` rows (where the category tracks a person)
  into root-cause buckets — resolved, recoverable by resolver, and rows that
  need a source reimport.

  ## Usage

      mix cinegraph.audit.award_person_linkage
      mix cinegraph.audit.award_person_linkage --org HFPA
      mix cinegraph.audit.award_person_linkage --org HFPA --json
      mix cinegraph.audit.award_person_linkage --limit 10

  ## Options

    * `--org` — festival organization abbreviation (e.g. `HFPA`, `AMPAS`).
      Omit to audit all organizations.
    * `--json` — emit JSON (suitable for piping to `jq`).
    * `--limit` — number of example rows to include (default: 5).

  See `mix cinegraph.prod.audit.award_person_linkage` for the production variant.
  """

  use Mix.Task

  alias Cinegraph.Health.AwardPersonLinkage

  @shortdoc "Audit festival nomination person-award linkage drift"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, invalid} =
      OptionParser.parse(args, strict: [json: :boolean, org: :string, limit: :integer])

    raise_invalid_options!(invalid)

    org = Keyword.get(opts, :org)
    json? = Keyword.get(opts, :json, false)

    limit =
      case Keyword.get(opts, :limit, 5) do
        n when is_integer(n) and n > 0 -> n
        other -> Mix.raise("--limit must be a positive integer, got: #{inspect(other)}")
      end

    audit_opts = Enum.reject([org: org, limit: limit], fn {_k, v} -> is_nil(v) end)
    result = AwardPersonLinkage.audit(audit_opts)

    if json? do
      result
      |> Jason.encode!(pretty: true)
      |> IO.puts()
    else
      print_table(result)
    end
  end

  defp raise_invalid_options!([]), do: :ok

  defp raise_invalid_options!(invalid) do
    Mix.raise("invalid option(s): #{inspect(invalid)}")
  end

  defp print_table(%{organization: org, summary: s, examples: examples, generated_at: gen_at}) do
    Mix.shell().info("Award person-linkage audit — org=#{org}, generated #{gen_at}")
    Mix.shell().info(String.duplicate("=", 70))

    rows = [
      {"person_required_total", s.person_required_total},
      {"resolved", s.resolved},
      {"missing_person_id", s.missing_person_id},
      {"  recoverable_with_imdb_id", s.recoverable_with_imdb_id},
      {"  recoverable_with_name", s.recoverable_with_name},
      {"  has_people_in_details", s.has_people_in_details},
      {"  empty_person_payload", s.empty_person_payload},
      {"  needs_reimport", s.needs_reimport}
    ]

    Enum.each(rows, fn {label, count} ->
      Mix.shell().info(String.pad_trailing(label, 34) <> String.pad_leading(to_string(count), 10))
    end)

    unless examples == [] do
      Mix.shell().info("")
      Mix.shell().info("examples (person_id IS NULL):")
      Mix.shell().info(String.duplicate("-", 70))

      Enum.each(examples, fn ex ->
        flags =
          [
            ex.has_imdb_ids && "imdb_ids",
            ex.has_nominee_name && "name",
            ex.has_people_in_details && "people_list"
          ]
          |> Enum.filter(& &1)
          |> Enum.join(",")

        flags = if flags == "", do: "empty_payload", else: flags

        Mix.shell().info(
          "  id=#{ex.id} category=#{ex.category} ceremony=#{ex.ceremony_id} [#{flags}]"
        )
      end)
    end
  end
end

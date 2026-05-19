defmodule Mix.Tasks.Cinegraph.Prod.Audit.AwardPersonLinkage do
  @moduledoc """
  Run the award person-linkage audit against production via `kamal app exec`.
  Calls `Cinegraph.Health.AwardPersonLinkage.audit/1` inside the running prod
  container and prints the result locally.

  ## Usage

      mix cinegraph.prod.audit.award_person_linkage
      mix cinegraph.prod.audit.award_person_linkage --org HFPA
      mix cinegraph.prod.audit.award_person_linkage --org HFPA --json
      mix cinegraph.prod.audit.award_person_linkage --limit 10

  ## Options

    * `--org` — festival organization abbreviation (e.g. `HFPA`, `AMPAS`).
    * `--json` — emit JSON (suitable for piping to `jq`).
    * `--limit` — number of example rows (default: 5).

  Requires the `kamal` CLI on PATH. See MAINTENANCE.md → "Audits & ad-hoc
  reports".
  """

  use Mix.Task

  alias Cinegraph.ProdRpc

  @shortdoc "Audit festival person-award linkage on production"

  @impl Mix.Task
  def run(args) do
    {opts, _, invalid} =
      OptionParser.parse(args, strict: [json: :boolean, org: :string, limit: :integer])

    raise_invalid_options!(invalid)

    org = Keyword.get(opts, :org)

    limit =
      case Keyword.get(opts, :limit, 5) do
        n when is_integer(n) and n > 0 -> n
        other -> Mix.raise("--limit must be a positive integer, got: #{inspect(other)}")
      end

    audit_opts = build_audit_opts(org, limit)
    expr = ~s|IO.puts(Jason.encode!(Cinegraph.Health.AwardPersonLinkage.audit(#{audit_opts})))|

    case ProdRpc.eval_json(expr) do
      {:ok, audit} -> ProdRpc.print(audit, opts)
      {:error, reason} -> ProdRpc.print_error(reason)
    end
  end

  defp build_audit_opts(org, limit) do
    parts =
      [
        org && "org: #{inspect(org)}",
        "limit: #{limit}"
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(", ")

    "[#{parts}]"
  end

  defp raise_invalid_options!([]), do: :ok

  defp raise_invalid_options!(invalid) do
    Mix.raise("invalid option(s): #{inspect(invalid)}")
  end
end

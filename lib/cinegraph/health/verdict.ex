defmodule Cinegraph.Health.Verdict do
  @moduledoc """
  Pure rollup logic — no DB, no I/O. Takes a map of drift results
  per domain and produces a colored verdict.

  Thresholds come from `Application.get_env(:cinegraph, :health)[:thresholds]`.
  Each check is colored individually; domain status = worst of its checks;
  overall status = worst across domains.

  ## Threshold semantics

  Threshold tuples are `{green_max, amber_max}`. Comparison metric is
  `affected_pct` (float) when the tuple values are floats, or
  `affected_count` (integer) when they're integers.
  """

  @type drift_result :: map()
  @type domain_results :: %{atom() => [drift_result()]}

  @domain_priority [:people, :movies, :festivals, :ratings, :collaborations]
  @status_priority %{red: 3, amber: 2, green: 1, unknown: 0}

  @doc """
  Compute a full rollup from per-domain results.

  ## Input

      %{
        people:    [drift_result, ...],
        movies:    [drift_result, ...],
        festivals: [drift_result, ...],
        ratings:   [drift_result, ...]
      }

  ## Output

      %{
        generated_at: ~U[...],
        status: :amber,
        worst_check: %{...},
        domains: %{
          people:    %{status: :amber, checks: [<colored result>, ...]},
          ...
        }
      }
  """
  def compute(domain_results) when is_map(domain_results) do
    thresholds = thresholds_config()

    colored_domains =
      domain_results
      |> Enum.map(fn {domain, checks} ->
        colored_checks =
          Enum.map(checks, fn check -> color_check(check, thresholds) end)

        domain_status = domain_rollup(colored_checks)

        {domain, %{status: domain_status, checks: colored_checks}}
      end)
      |> Enum.into(%{})

    overall_status = overall_rollup(colored_domains)
    worst = find_worst_check(colored_domains)

    %{
      generated_at: DateTime.utc_now(),
      status: overall_status,
      worst_check: worst,
      domains: colored_domains
    }
  end

  @doc """
  Color a single drift result. Pure — used internally by `compute/1` but
  exposed for unit tests.
  """
  def color_check(check, thresholds) do
    cond do
      check[:blocked_reason] != nil ->
        %{check | status: :unknown}

      true ->
        domain = check.domain
        check_name = check.check
        {green_max, amber_max} = lookup_threshold(thresholds, domain, check_name)
        metric = pick_metric(check, green_max)

        status =
          cond do
            metric <= green_max -> :green
            metric <= amber_max -> :amber
            true -> :red
          end

        %{check | status: status}
    end
  end

  defp lookup_threshold(thresholds, domain, check_name) do
    domain_thresholds = Map.get(thresholds, domain, %{})

    Map.get(domain_thresholds, check_name) ||
      Map.get(thresholds, :default, {1.0, 10.0})
  end

  # Integer thresholds → compare against affected_count.
  # Float thresholds → compare against affected_pct.
  defp pick_metric(check, green_max) when is_integer(green_max), do: check.affected_count

  defp pick_metric(check, _green_max), do: check.affected_pct

  defp domain_rollup([]), do: :unknown

  defp domain_rollup(colored_checks) do
    colored_checks
    |> Enum.map(& &1.status)
    |> Enum.max_by(fn status -> Map.get(@status_priority, status, 0) end, fn -> :unknown end)
  end

  defp overall_rollup(colored_domains) when colored_domains == %{}, do: :unknown

  defp overall_rollup(colored_domains) do
    colored_domains
    |> Enum.map(fn {_, %{status: s}} -> s end)
    |> Enum.max_by(fn status -> Map.get(@status_priority, status, 0) end, fn -> :unknown end)
  end

  # Worst check: highest priority status; ties broken by domain priority order.
  defp find_worst_check(colored_domains) do
    @domain_priority
    |> Enum.flat_map(fn domain ->
      case Map.get(colored_domains, domain) do
        %{checks: checks} -> checks
        _ -> []
      end
    end)
    |> Enum.max_by(
      fn check -> Map.get(@status_priority, check.status, 0) end,
      fn -> nil end
    )
  end

  defp thresholds_config do
    case Application.get_env(:cinegraph, :health) do
      nil -> %{}
      config -> Keyword.get(config, :thresholds, %{})
    end
  end
end

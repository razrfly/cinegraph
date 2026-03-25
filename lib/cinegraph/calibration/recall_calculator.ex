defmodule Cinegraph.Calibration.RecallCalculator do
  @moduledoc """
  Measures recall of a reference list against a scoring profile.

  Determines what percentage of reference films appear in the algorithm's
  top-ranked results (default: top 25% per decade).
  """

  import Ecto.Query

  alias Cinegraph.Repo
  alias Cinegraph.Movies.Movie
  alias Cinegraph.Calibration
  alias Cinegraph.Metrics.ScoringService

  @default_threshold 0.25
  @default_list_slug "1001-movies"
  @default_profile "Cinegraph Editorial"

  @doc """
  Measures recall for a reference list against a scoring profile.

  Returns a map:
    %{
      overall_recall: float,
      total_found: int,
      total_reference: int,
      by_decade: %{decade_int => %{recall, found, total, threshold_count, total_in_db, decade_label, missed_ids}},
      lens_correlations: [%{lens, label, mean_score}] sorted desc,
      systematic_gaps: [%{category, count, description}]
    }

  Or `{:error, reason}` if the list or references are not found.
  """
  def measure(list_slug \\ @default_list_slug, profile_name \\ @default_profile, opts \\ []) do
    threshold = Keyword.get(opts, :threshold, @default_threshold)

    case Calibration.get_reference_list_by_slug(list_slug) do
      nil ->
        {:error, :list_not_found}

      ref_list ->
        references =
          Calibration.list_references(ref_list.id, include_unmatched: false, limit: 9999)

        if references == [] do
          {:error, :no_matched_references}
        else
          profile =
            ScoringService.get_profile(profile_name) || ScoringService.get_default_profile()

          do_measure(references, profile, threshold)
        end
    end
  end

  defp do_measure(references, profile, threshold) do
    by_decade_refs = group_by_decade(references)

    # Per-decade recall (parallel, max 1 concurrent DB query)
    decade_results_result =
      by_decade_refs
      |> Task.async_stream(
        fn {decade, refs} ->
          compute_decade_recall(decade, refs, profile, threshold)
        end,
        max_concurrency: 1,
        timeout: 300_000
      )
      |> Enum.reduce_while({:ok, %{}}, fn
        {:ok, result}, {:ok, acc} -> {:cont, {:ok, Map.put(acc, result.decade, result)}}
        {:exit, reason}, _acc -> {:halt, {:error, reason}}
      end)

    case decade_results_result do
      {:error, reason} ->
        {:error, reason}

      {:ok, decade_results} ->
        total_found = Enum.sum(Enum.map(decade_results, fn {_, r} -> r.found end))
        total_reference = length(references)

        lens_correlations = calculate_lens_correlations(references, profile)
        systematic_gaps = find_systematic_gaps(references, decade_results)

        %{
          overall_recall: if(total_reference > 0, do: total_found / total_reference, else: 0.0),
          total_found: total_found,
          total_reference: total_reference,
          by_decade: decade_results,
          lens_correlations: lens_correlations,
          systematic_gaps: systematic_gaps
        }
    end
  end

  # ---------------------------------------------------------------------------
  # Decade grouping
  # ---------------------------------------------------------------------------

  defp group_by_decade(references) do
    references
    |> Enum.group_by(fn ref ->
      case get_reference_year(ref) do
        nil -> nil
        year -> div(year, 10)
      end
    end)
    |> Map.delete(nil)
  end

  defp get_reference_year(%{movie: %Movie{release_date: %Date{year: year}}}), do: year

  defp get_reference_year(%{movie: %Movie{release_date: date}}) when not is_nil(date) do
    case date do
      %{year: year} -> year
      _ -> nil
    end
  end

  defp get_reference_year(%{external_year: year}) when is_integer(year), do: year
  defp get_reference_year(_), do: nil

  # ---------------------------------------------------------------------------
  # Per-decade recall
  # ---------------------------------------------------------------------------

  defp compute_decade_recall(decade, refs, profile, threshold) do
    year_start = decade * 10
    year_end = year_start + 9
    start_date = Date.new!(year_start, 1, 1)
    end_date = Date.new!(year_end, 12, 31)

    total_in_db =
      from(m in Movie,
        where: not is_nil(m.release_date),
        where: m.release_date >= ^start_date,
        where: m.release_date <= ^end_date
      )
      |> Repo.aggregate(:count, timeout: 120_000)

    threshold_count = max(1, round(total_in_db * threshold))

    top_ids =
      from(m in Movie,
        where: not is_nil(m.release_date),
        where: m.release_date >= ^start_date,
        where: m.release_date <= ^end_date
      )
      |> ScoringService.apply_scoring(profile, %{min_score: nil})
      |> limit(^threshold_count)
      |> Repo.all(timeout: 300_000)
      |> Enum.map(& &1.id)
      |> MapSet.new()

    ref_ids =
      refs
      |> Enum.map(& &1.movie_id)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    missed_ids = MapSet.difference(ref_ids, top_ids)
    found = MapSet.size(ref_ids) - MapSet.size(missed_ids)
    total = MapSet.size(ref_ids)

    %{
      decade: decade,
      decade_label: "#{year_start}s",
      recall: if(total > 0, do: found / total, else: 0.0),
      found: found,
      total: total,
      threshold_count: threshold_count,
      total_in_db: total_in_db,
      missed_ids: MapSet.to_list(missed_ids)
    }
  end

  # ---------------------------------------------------------------------------
  # Lens correlations
  # ---------------------------------------------------------------------------

  defp calculate_lens_correlations(references, profile) do
    ref_movie_ids =
      references
      |> Enum.map(& &1.movie_id)
      |> Enum.reject(&is_nil/1)

    if ref_movie_ids == [] do
      []
    else
      scored =
        from(m in Movie, where: m.id in ^ref_movie_ids)
        |> ScoringService.apply_scoring(profile, %{min_score: nil})
        |> Repo.all()

      lenses = [
        {:mob, "Mob (Audience)"},
        {:ivory_tower, "Ivory Tower (Critics)"},
        {:festival_recognition, "Industry Recognition"},
        {:cultural_impact, "Cultural Impact"},
        {:people_quality, "People Quality"},
        {:financial_performance, "Financial Performance"}
      ]

      Enum.map(lenses, fn {lens, label} ->
        scores =
          scored
          |> Enum.map(fn m ->
            components = Map.get(m, :score_components) || Map.get(m, "score_components") || %{}
            Map.get(components, lens) || Map.get(components, to_string(lens))
          end)
          |> Enum.filter(&is_number/1)

        mean =
          if scores != [] do
            Float.round(Enum.sum(scores) / length(scores), 4)
          else
            0.0
          end

        %{lens: lens, label: label, mean_score: mean}
      end)
      |> Enum.sort_by(& &1.mean_score, :desc)
    end
  end

  # ---------------------------------------------------------------------------
  # Systematic gaps
  # ---------------------------------------------------------------------------

  defp find_systematic_gaps(references, decade_results) do
    missed_ids =
      decade_results
      |> Enum.flat_map(fn {_, r} -> Map.get(r, :missed_ids, []) end)
      |> MapSet.new()

    if MapSet.size(missed_ids) == 0 do
      []
    else
      missed_list = MapSet.to_list(missed_ids)

      (analyze_language_gaps(missed_list) ++
         analyze_decade_gaps(decade_results) ++
         analyze_genre_gaps(missed_list, references))
      |> Enum.sort_by(& &1.count, :desc)
    end
  end

  defp analyze_language_gaps(missed_ids) when missed_ids == [], do: []

  defp analyze_language_gaps(missed_ids) do
    from(m in Movie,
      where: m.id in ^missed_ids,
      where: not is_nil(m.original_language),
      where: m.original_language != "en",
      group_by: m.original_language,
      order_by: [desc: count(m.id)],
      limit: 5,
      select: {m.original_language, count(m.id)}
    )
    |> Repo.all()
    |> Enum.map(fn {lang, count} ->
      %{
        category: "language",
        count: count,
        description: "Non-English films (#{String.upcase(lang)}): #{count} missed"
      }
    end)
  end

  defp analyze_decade_gaps(decade_results) do
    decade_results
    |> Enum.filter(fn {_, r} -> r.total > 0 and r.recall < 0.50 end)
    |> Enum.map(fn {_, r} ->
      %{
        category: "decade",
        count: r.total - r.found,
        description:
          "#{r.decade_label}: #{Float.round(r.recall * 100, 0)}% recall (#{r.found}/#{r.total})"
      }
    end)
  end

  defp analyze_genre_gaps(missed_ids, _references) when missed_ids == [], do: []

  defp analyze_genre_gaps(missed_ids, _references) do
    from(m in Movie,
      where: m.id in ^missed_ids,
      where: not is_nil(m.tmdb_data),
      select: fragment("?->'genres'", m.tmdb_data)
    )
    |> Repo.all()
    |> Enum.flat_map(fn genres ->
      case genres do
        genres when is_list(genres) ->
          Enum.map(genres, fn g ->
            cond do
              is_map(g) -> Map.get(g, "name") || Map.get(g, :name)
              true -> nil
            end
          end)

        _ ->
          []
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.frequencies()
    |> Enum.sort_by(fn {_, count} -> count end, :desc)
    |> Enum.take(3)
    |> Enum.map(fn {genre, count} ->
      %{
        category: "genre",
        count: count,
        description: "Genre '#{genre}': #{count} missed films"
      }
    end)
  end
end

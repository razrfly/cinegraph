defmodule Cinegraph.Maintenance.Companies do
  @moduledoc """
  Audit and refresh helpers for production-company metadata.
  """

  import Ecto.Query

  alias Cinegraph.Movies
  alias Cinegraph.Movies.Movie
  alias Cinegraph.Repo

  @stale_days 180

  def audit(opts \\ []) do
    top_limit = Keyword.get(opts, :top_limit, 10)
    companies = Movies.list_production_companies_with_stats(include_orphans: true)

    stats = %{
      total_companies: length(companies),
      companies_with_slugs: Enum.count(companies, &present?(&1.slug)),
      companies_missing_slugs: Enum.count(companies, &(not present?(&1.slug))),
      companies_with_movie_joins: Enum.count(companies, &(&1.movie_count > 0)),
      companies_without_movie_joins: Enum.count(companies, &(&1.movie_count == 0)),
      companies_with_logo_path: Enum.count(companies, &present?(&1.logo_path)),
      companies_with_logo_url: Enum.count(companies, &present?(&1.logo_url)),
      companies_with_svg_logo: Enum.count(companies, & &1.has_svg_logo),
      companies_with_tmdb_details_metadata: Enum.count(companies, &has_tmdb_details?/1),
      companies_with_tmdb_images_metadata: Enum.count(companies, &has_tmdb_images?/1),
      companies_missing_tmdb_details_metadata:
        Enum.count(companies, &(not has_tmdb_details?(&1))),
      companies_missing_tmdb_images_metadata: Enum.count(companies, &(not has_tmdb_images?(&1))),
      companies_missing_logo_url: Enum.count(companies, &(not present?(&1.logo_url))),
      companies_stale_metadata:
        Enum.count(companies, &Movies.production_company_metadata_stale?(&1, @stale_days)),
      top_missing_metadata_by_movie_count:
        top_missing(
          companies,
          top_limit,
          &(not has_tmdb_details?(&1) or not has_tmdb_images?(&1))
        ),
      top_missing_logo_by_movie_count:
        top_missing(
          companies,
          top_limit,
          &(not present?(&1.logo_url) and not present?(&1.logo_path))
        )
    }

    {:ok, stats}
  end

  def backfill_slugs do
    Movies.backfill_production_company_slugs()
  end

  def refresh_metadata(opts \\ []) do
    dry_run? = Keyword.get(opts, :dry_run, false)
    company_value = Keyword.get(opts, :company)
    limit = Keyword.get(opts, :limit, 100)
    mode = Keyword.get(opts, :mode, :missing)

    companies =
      case company_value do
        nil ->
          Movies.list_production_companies_for_metadata_refresh(mode: mode, limit: limit)

        value ->
          case Movies.find_production_company(value) do
            nil -> []
            company -> [company]
          end
      end

    if dry_run? do
      movie_counts = movie_counts_for(companies)

      {:ok,
       %{
         dry_run: true,
         found: length(companies),
         refreshed: 0,
         failed: 0,
         companies: shape(companies, movie_counts)
       }}
    else
      movie_counts = movie_counts_for(companies)
      results = Enum.map(companies, &Movies.refresh_production_company_metadata/1)

      {:ok,
       %{
         dry_run: false,
         found: length(companies),
         refreshed: Enum.count(results, &match?({:ok, _}, &1)),
         failed: Enum.count(results, &match?({:error, _}, &1)),
         companies: shape(companies, movie_counts),
         errors: errors(companies, results)
       }}
    end
  end

  def full_movie_count_for_company(company_id) do
    from(mpc in "movie_production_companies",
      join: m in Movie,
      on: m.id == mpc.movie_id,
      where: mpc.production_company_id == ^company_id and m.import_status == "full",
      select: count(m.id)
    )
    |> Repo.replica().one()
  end

  defp top_missing(companies, limit, predicate) do
    companies
    |> Enum.filter(predicate)
    |> Enum.sort_by(& &1.movie_count, :desc)
    |> Enum.take(limit)
    |> then(fn top_companies -> shape(top_companies, movie_counts_for(top_companies)) end)
  end

  defp shape(companies, movie_counts) do
    Enum.map(companies, fn company ->
      %{
        id: company.id,
        tmdb_id: company.tmdb_id,
        slug: company.slug,
        name: company.name,
        movie_count:
          Map.get(company, :movie_count) || Map.get(movie_counts, company.id) ||
            full_movie_count_for_company(company.id)
      }
    end)
  end

  defp movie_counts_for(companies) do
    companies
    |> Enum.map(& &1.id)
    |> Movies.count_movies_by_production_company_ids()
  end

  defp errors(companies, results) do
    companies
    |> Enum.zip(results)
    |> Enum.flat_map(fn
      {company, {:error, reason}} ->
        [%{id: company.id, name: company.name, error: inspect(reason)}]

      _ ->
        []
    end)
  end

  defp has_tmdb_details?(company),
    do: not is_nil(get_in(ensure_map(company.metadata), ["tmdb", "company_details"]))

  defp has_tmdb_images?(company),
    do: not is_nil(get_in(ensure_map(company.metadata), ["tmdb", "company_images"]))

  defp ensure_map(value) when is_map(value), do: value
  defp ensure_map(_value), do: %{}

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false
end

defmodule Cinegraph.Workers.SlugBackfillWorker do
  @moduledoc """
  Background worker for backfilling slugs on existing records.

  This worker handles:
  1. Regenerating broken movie slugs (non-Latin character issues)
  2. Generating slugs for people (new field)

  Uses batch processing with configurable batch size to avoid
  memory issues and allow for graceful interruption.
  """

  use Oban.Worker, queue: :default, max_attempts: 3

  require Logger
  import Ecto.Query

  alias Cinegraph.Repo
  alias Cinegraph.Movies.{Movie, Person}
  alias Cinegraph.Slugs.SlugUtils

  @batch_size 100

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"operation" => "backfill_movie_slugs", "last_id" => last_id}}) do
    Logger.info("Continuing movie slug backfill job after ID #{last_id}")
    backfill_movie_slugs_batch(last_id)
  end

  def perform(%Oban.Job{args: %{"operation" => "backfill_movie_slugs"}}) do
    Logger.info("Starting movie slug backfill job")
    backfill_movie_slugs()
  end

  def perform(%Oban.Job{args: %{"operation" => "backfill_people_slugs", "last_id" => last_id}}) do
    Logger.info("Continuing people slug backfill job after ID #{last_id}")
    backfill_people_slugs_batch(last_id)
  end

  def perform(%Oban.Job{args: %{"operation" => "backfill_people_slugs"}}) do
    Logger.info("Starting people slug backfill job")
    backfill_people_slugs()
  end

  def perform(%Oban.Job{args: %{"operation" => "fix_broken_movie_slugs"}}) do
    Logger.info("Starting broken movie slug fix job")
    fix_broken_movie_slugs()
  end

  def perform(%Oban.Job{args: args}) do
    Logger.warning("Unknown slug backfill operation: #{inspect(args)}")
    {:error, "Unknown operation"}
  end

  # Fix broken movie slugs (starting with hyphen or containing special chars)
  defp fix_broken_movie_slugs do
    # Find movies with broken slugs
    broken_slugs_query =
      from m in Movie,
        where: like(m.slug, "-%") or like(m.slug, "%　%"),
        select: m.id

    broken_ids = Repo.all(broken_slugs_query)
    total = length(broken_ids)

    Logger.info("Found #{total} movies with broken slugs to fix")

    broken_ids
    |> Enum.with_index(1)
    |> Enum.each(fn {movie_id, index} ->
      fix_movie_slug(movie_id)

      if rem(index, 100) == 0 do
        Logger.info("Fixed #{index}/#{total} movie slugs")
      end
    end)

    Logger.info("Completed fixing #{total} broken movie slugs")
    :ok
  end

  defp fix_movie_slug(movie_id) do
    movie = Repo.get(Movie, movie_id)

    if movie do
      # Get the year from release_date
      year = SlugUtils.extract_year(movie.release_date)

      # Generate new slug using SlugUtils
      new_base_slug = SlugUtils.create_slug_with_year(movie.title, year)

      # Check if this slug already exists
      new_slug = ensure_unique_movie_slug(new_base_slug, movie_id, movie)

      # Update the movie directly with raw SQL to bypass slug generation
      Repo.query!(
        "UPDATE movies SET slug = $1, updated_at = $2 WHERE id = $3",
        [new_slug, NaiveDateTime.utc_now(), movie_id]
      )
    end
  end

  defp ensure_unique_movie_slug(base_slug, movie_id, movie) do
    if movie_slug_exists?(base_slug, movie_id) do
      # Try country fallback
      case movie.origin_country do
        [country | _] when is_binary(country) ->
          country_slug = "#{base_slug}-#{SlugUtils.normalize_country(country)}"

          if !movie_slug_exists?(country_slug, movie_id) do
            country_slug
          else
            add_sequential_movie_slug(base_slug, movie_id)
          end

        _ ->
          add_sequential_movie_slug(base_slug, movie_id)
      end
    else
      base_slug
    end
  end

  defp movie_slug_exists?(slug, movie_id) do
    query =
      from m in Movie,
        where: m.slug == ^slug and m.id != ^movie_id

    Repo.exists?(query)
  end

  defp add_sequential_movie_slug(base_slug, movie_id) do
    # Find existing sequential slugs
    pattern = "#{base_slug}-%"

    existing =
      from(m in Movie, where: ilike(m.slug, ^pattern) and m.id != ^movie_id, select: m.slug)
      |> Repo.all()

    next_num = find_next_number(existing, base_slug)
    "#{base_slug}-#{next_num}"
  end

  defp find_next_number(existing_slugs, base_slug) do
    numbers =
      existing_slugs
      |> Enum.map(fn slug ->
        case Regex.run(~r/#{Regex.escape(base_slug)}-(\d+)$/, slug) do
          [_, num_str] -> String.to_integer(num_str)
          _ -> 0
        end
      end)
      |> Enum.filter(&(&1 > 0))
      |> Enum.sort()

    case numbers do
      [] -> 2
      list -> List.last(list) + 1
    end
  end

  # Backfill movie slugs (regenerate all using new SlugUtils)
  # Uses cursor-based batching to ensure partial progress is persisted across job retries
  defp backfill_movie_slugs do
    total =
      from(m in Movie, select: count(m.id))
      |> Repo.one()

    Logger.info("Starting full movie slug backfill for #{total} movies")

    # Start with ID 0 to get all records with ID > 0
    backfill_movie_slugs_batch(0)
  end

  defp backfill_movie_slugs_batch(last_id) do
    # Get a batch of movies using ID cursor for reliable pagination
    movies =
      from(m in Movie,
        where: m.id > ^last_id,
        order_by: m.id,
        limit: ^@batch_size,
        select: m.id
      )
      |> Repo.all()

    batch_count = length(movies)

    if batch_count > 0 do
      # Get the last ID from this batch for cursor-based pagination
      max_id = List.last(movies)
      Logger.info("Processing batch of #{batch_count} movies (IDs #{last_id + 1} to #{max_id})")

      Enum.each(movies, fn movie_id ->
        fix_movie_slug(movie_id)
      end)

      # Schedule next batch if there might be more
      if batch_count == @batch_size do
        schedule_next_movie_batch(max_id)
      else
        Logger.info("Completed movie slug backfill (last batch)")
      end

      :ok
    else
      Logger.info("Completed movie slug backfill (no more records)")
      :ok
    end
  end

  # Backfill people slugs
  defp backfill_people_slugs do
    total =
      from(p in Person, where: is_nil(p.slug), select: count(p.id))
      |> Repo.one()

    Logger.info("Found #{total} people without slugs to backfill")

    if total > 0 do
      # Start with ID 0 to get all records with ID > 0
      backfill_people_slugs_batch(0)
    else
      Logger.info("No people need slug backfill")
      :ok
    end
  end

  defp backfill_people_slugs_batch(last_id) do
    # Get a batch of people without slugs using ID cursor instead of offset.
    # This avoids skipping records when the result set shrinks as records get slugs.
    people =
      from(p in Person,
        where: is_nil(p.slug) and p.id > ^last_id,
        order_by: p.id,
        limit: ^@batch_size
      )
      |> Repo.all()

    batch_count = length(people)

    if batch_count > 0 do
      # Get the last ID from this batch for cursor-based pagination
      max_id = List.last(people).id
      Logger.info("Processing batch of #{batch_count} people (IDs #{last_id + 1} to #{max_id})")

      Enum.each(people, fn person ->
        generate_person_slug(person)
      end)

      # Schedule next batch if there might be more
      if batch_count == @batch_size do
        schedule_next_people_batch(max_id)
      else
        Logger.info("Completed people slug backfill (last batch)")
      end

      :ok
    else
      Logger.info("Completed people slug backfill (no more records)")
      :ok
    end
  end

  defp generate_person_slug(person) do
    base_slug = SlugUtils.slugify(person.name)
    new_slug = ensure_unique_person_slug(base_slug, person.id, person)

    # Update directly with raw SQL
    Repo.query!(
      "UPDATE people SET slug = $1, updated_at = $2 WHERE id = $3",
      [new_slug, NaiveDateTime.utc_now(), person.id]
    )
  end

  defp ensure_unique_person_slug(base_slug, person_id, person) do
    if person_slug_exists?(base_slug, person_id) do
      # Try birth year fallback
      case person.birthday do
        %Date{year: year} ->
          year_slug = "#{base_slug}-#{year}"

          if !person_slug_exists?(year_slug, person_id) do
            year_slug
          else
            try_country_or_tmdb_fallback(base_slug, person_id, person)
          end

        _ ->
          try_country_or_tmdb_fallback(base_slug, person_id, person)
      end
    else
      base_slug
    end
  end

  defp try_country_or_tmdb_fallback(base_slug, person_id, person) do
    # Try country from place_of_birth
    country_code = extract_country_from_place(person.place_of_birth)

    if country_code do
      country_slug = "#{base_slug}-#{country_code}"

      if !person_slug_exists?(country_slug, person_id) do
        country_slug
      else
        tmdb_fallback(person)
      end
    else
      tmdb_fallback(person)
    end
  end

  defp tmdb_fallback(person) do
    case person.tmdb_id do
      nil -> "person-#{person.id}"
      tmdb_id -> "tmdb-#{tmdb_id}"
    end
  end

  defp extract_country_from_place(nil), do: nil
  defp extract_country_from_place(""), do: nil

  defp extract_country_from_place(place) do
    country =
      place
      |> String.split(",")
      |> List.last()
      |> String.trim()
      |> String.downcase()

    country_mapping = %{
      "usa" => "us",
      "united states" => "us",
      "united states of america" => "us",
      "uk" => "uk",
      "united kingdom" => "uk",
      "england" => "uk",
      "canada" => "ca",
      "australia" => "au",
      "japan" => "jp",
      "china" => "cn",
      "south korea" => "kr",
      "france" => "fr",
      "germany" => "de",
      "italy" => "it",
      "spain" => "es",
      "mexico" => "mx",
      "brazil" => "br",
      "india" => "in",
      "russia" => "ru",
      "sweden" => "se"
    }

    Map.get(country_mapping, country)
  end

  defp person_slug_exists?(slug, person_id) do
    query =
      from p in Person,
        where: p.slug == ^slug and p.id != ^person_id

    Repo.exists?(query)
  end

  defp schedule_next_movie_batch(last_id) do
    %{operation: "backfill_movie_slugs", last_id: last_id}
    |> new(schedule_in: 1)
    |> Oban.insert()
  end

  defp schedule_next_people_batch(last_id) do
    %{operation: "backfill_people_slugs", last_id: last_id}
    |> new(schedule_in: 1)
    |> Oban.insert()
  end

  # Public API for scheduling jobs

  @doc """
  Schedule a job to fix broken movie slugs.
  """
  def schedule_fix_broken_movie_slugs do
    %{operation: "fix_broken_movie_slugs"}
    |> new()
    |> Oban.insert()
  end

  @doc """
  Schedule a job to backfill all movie slugs.
  """
  def schedule_backfill_movie_slugs do
    %{operation: "backfill_movie_slugs"}
    |> new()
    |> Oban.insert()
  end

  @doc """
  Schedule a job to backfill people slugs.
  """
  def schedule_backfill_people_slugs do
    %{operation: "backfill_people_slugs"}
    |> new()
    |> Oban.insert()
  end
end

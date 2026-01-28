defmodule Cinegraph.Services.TMDb.DailyExport do
  @moduledoc """
  Downloads and parses TMDb daily ID export files.

  TMDb publishes daily export files containing all valid movie IDs at:
  http://files.tmdb.org/p/exports/movie_ids_MM_DD_YYYY.json.gz

  The files are line-delimited JSON (not a single JSON array), gzipped.
  Each line contains: {"adult":false,"id":123,"original_title":"...","popularity":1.23,"video":false}

  ## Usage

      # Download today's export
      {:ok, path} = DailyExport.download()

      # Stream movie entries (memory efficient)
      DailyExport.stream_movies(path)
      |> Stream.filter(& &1.popularity >= 1.0)
      |> Enum.take(100)

      # Get all IDs as a list
      {:ok, ids} = DailyExport.get_all_ids(path)
  """

  require Logger

  @base_url "http://files.tmdb.org/p/exports"
  # 5 minutes for large files
  @download_timeout 300_000

  @type movie_entry :: %{
          id: integer(),
          original_title: String.t(),
          popularity: float(),
          adult: boolean(),
          video: boolean()
        }

  @doc """
  Downloads the movie IDs export file for a given date.
  Returns the path to the downloaded (decompressed) file.

  ## Options
    - `:date` - Date to download (default: today)
    - `:dest_dir` - Directory to save file (default: System.tmp_dir())
    - `:keep_gzipped` - Keep the gzipped version (default: false)

  ## Examples

      {:ok, path} = DailyExport.download()
      {:ok, path} = DailyExport.download(date: ~D[2026-01-05])
  """
  @spec download(keyword()) :: {:ok, String.t()} | {:error, term()}
  def download(opts \\ []) do
    date = Keyword.get(opts, :date, Date.utc_today())
    dest_dir = Keyword.get(opts, :dest_dir, System.tmp_dir!())
    # Allow fallback to previous days if today's file isn't available yet
    fallback_days = Keyword.get(opts, :fallback_days, 3)

    try_download_with_fallback(date, dest_dir, fallback_days)
  end

  defp try_download_with_fallback(date, dest_dir, days_remaining) when days_remaining > 0 do
    filename = format_filename(date)
    url = "#{@base_url}/#{filename}"
    gz_path = Path.join(dest_dir, filename)
    json_path = String.replace(gz_path, ".gz", "")

    Logger.info("Downloading TMDb export: #{url}")

    case download_file(url, gz_path) do
      {:ok, _} ->
        with {:ok, _} <- decompress_file(gz_path, json_path) do
          File.rm(gz_path)
          Logger.info("Downloaded and decompressed to: #{json_path}")
          {:ok, json_path}
        end

      {:error, {:http_error, 403}} ->
        # 403 usually means file not yet published (TMDb publishes ~8 AM UTC)
        # Try the previous day's file
        yesterday = Date.add(date, -1)
        Logger.info("Today's export not available yet (403), trying #{yesterday}...")
        try_download_with_fallback(yesterday, dest_dir, days_remaining - 1)

      {:error, :not_found} ->
        # 404 - file doesn't exist, try previous day
        yesterday = Date.add(date, -1)
        Logger.info("Export not found (404), trying #{yesterday}...")
        try_download_with_fallback(yesterday, dest_dir, days_remaining - 1)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp try_download_with_fallback(date, _dest_dir, 0) do
    Logger.error("TMDb export not available after fallback attempts. Last tried: #{date}")
    {:error, :export_unavailable}
  end

  @doc """
  Returns the URL for a given date's export file.
  """
  @spec export_url(Date.t()) :: String.t()
  def export_url(date \\ Date.utc_today()) do
    "#{@base_url}/#{format_filename(date)}"
  end

  @doc """
  Streams movie entries from an export file.
  Memory efficient - processes one line at a time.

  ## Options
    - `:skip_video` - Skip entries where video=true (default: true)
    - `:skip_adult` - Skip entries where adult=true (default: true)
    - `:min_popularity` - Minimum popularity threshold (default: nil)

  ## Examples

      DailyExport.stream_movies(path)
      |> Stream.filter(& &1.popularity >= 10)
      |> Enum.each(&process/1)
  """
  @spec stream_movies(String.t(), keyword()) :: Enumerable.t()
  def stream_movies(path, opts \\ []) do
    skip_video = Keyword.get(opts, :skip_video, true)
    skip_adult = Keyword.get(opts, :skip_adult, true)
    min_popularity = Keyword.get(opts, :min_popularity, nil)

    File.stream!(path)
    |> Stream.map(&String.trim/1)
    |> Stream.reject(&(&1 == ""))
    |> Stream.map(&parse_line/1)
    |> Stream.reject(&is_nil/1)
    |> Stream.reject(fn entry ->
      (skip_video && entry.video) ||
        (skip_adult && entry.adult) ||
        (min_popularity && entry.popularity < min_popularity)
    end)
  end

  @doc """
  Streams just the movie IDs from an export file.
  """
  @spec stream_ids(String.t(), keyword()) :: Enumerable.t()
  def stream_ids(path, opts \\ []) do
    stream_movies(path, opts)
    |> Stream.map(& &1.id)
  end

  @doc """
  Gets all movie IDs from an export file as a MapSet.
  Note: This loads all IDs into memory.
  """
  @spec get_all_ids(String.t(), keyword()) :: {:ok, MapSet.t()} | {:error, term()}
  def get_all_ids(path, opts \\ []) do
    try do
      ids =
        stream_ids(path, opts)
        |> Enum.into(MapSet.new())

      {:ok, ids}
    rescue
      e -> {:error, e}
    end
  end

  @doc """
  Counts entries in an export file by category.
  """
  @spec count_entries(String.t()) :: map()
  def count_entries(path) do
    File.stream!(path)
    |> Stream.map(&String.trim/1)
    |> Stream.reject(&(&1 == ""))
    |> Stream.map(&parse_line/1)
    |> Stream.reject(&is_nil/1)
    |> Enum.reduce(
      %{
        total: 0,
        video: 0,
        non_video: 0,
        adult: 0,
        pop_100_plus: 0,
        pop_50_100: 0,
        pop_10_50: 0,
        pop_1_10: 0,
        pop_below_1: 0
      },
      fn entry, acc ->
        acc
        |> Map.update!(:total, &(&1 + 1))
        |> Map.update!(:video, &(&1 + if(entry.video, do: 1, else: 0)))
        |> Map.update!(:non_video, &(&1 + if(entry.video, do: 0, else: 1)))
        |> Map.update!(:adult, &(&1 + if(entry.adult, do: 1, else: 0)))
        |> update_popularity_bucket(entry.popularity)
      end
    )
  end

  @doc """
  Gets popularity distribution statistics.
  """
  @spec popularity_distribution(String.t()) :: list()
  def popularity_distribution(path) do
    stream_movies(path, skip_video: true, skip_adult: true)
    |> Enum.reduce(%{}, fn entry, acc ->
      bucket = popularity_bucket(entry.popularity)
      Map.update(acc, bucket, 1, &(&1 + 1))
    end)
    |> Enum.sort_by(fn {bucket, _} -> bucket_order(bucket) end)
  end

  @doc """
  Gets sample movies by popularity tier.
  """
  @spec sample_by_popularity(String.t(), integer()) :: map()
  def sample_by_popularity(path, samples_per_tier \\ 5) do
    stream_movies(path, skip_video: true, skip_adult: true)
    |> Enum.reduce(%{high: [], medium: [], low: []}, fn entry, acc ->
      tier =
        cond do
          entry.popularity >= 10 -> :high
          entry.popularity >= 1 -> :medium
          true -> :low
        end

      if length(acc[tier]) < samples_per_tier do
        Map.update!(acc, tier, &[entry | &1])
      else
        acc
      end
    end)
  end

  # Private functions

  defp format_filename(date) do
    month = date.month |> Integer.to_string() |> String.pad_leading(2, "0")
    day = date.day |> Integer.to_string() |> String.pad_leading(2, "0")
    year = date.year
    "movie_ids_#{month}_#{day}_#{year}.json.gz"
  end

  defp download_file(url, dest_path) do
    Logger.info("Downloading from #{url}...")

    request = Finch.build(:get, url)

    case Finch.request(request, Cinegraph.Finch, receive_timeout: @download_timeout) do
      {:ok, %Finch.Response{status: 200, body: body}} ->
        File.write!(dest_path, body)
        size_mb = byte_size(body) / 1_048_576
        Logger.info("Downloaded #{Float.round(size_mb, 2)} MB")
        {:ok, dest_path}

      {:ok, %Finch.Response{status: 404}} ->
        {:error, :not_found}

      {:ok, %Finch.Response{status: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, {:network_error, reason}}
    end
  end

  defp decompress_file(gz_path, dest_path) do
    Logger.info("Decompressing #{gz_path}...")

    try do
      gz_data = File.read!(gz_path)
      json_data = :zlib.gunzip(gz_data)
      File.write!(dest_path, json_data)

      size_mb = byte_size(json_data) / 1_048_576
      Logger.info("Decompressed to #{Float.round(size_mb, 2)} MB")
      {:ok, dest_path}
    rescue
      e -> {:error, {:decompress_error, e}}
    end
  end

  defp parse_line(line) do
    case Jason.decode(line) do
      {:ok, data} ->
        %{
          id: data["id"],
          original_title: data["original_title"],
          popularity: data["popularity"] || 0.0,
          adult: data["adult"] || false,
          video: data["video"] || false
        }

      {:error, _} ->
        Logger.warning("Failed to parse line: #{String.slice(line, 0, 100)}")
        nil
    end
  end

  defp update_popularity_bucket(acc, popularity) do
    cond do
      popularity >= 100 -> Map.update!(acc, :pop_100_plus, &(&1 + 1))
      popularity >= 50 -> Map.update!(acc, :pop_50_100, &(&1 + 1))
      popularity >= 10 -> Map.update!(acc, :pop_10_50, &(&1 + 1))
      popularity >= 1 -> Map.update!(acc, :pop_1_10, &(&1 + 1))
      true -> Map.update!(acc, :pop_below_1, &(&1 + 1))
    end
  end

  defp popularity_bucket(pop) when pop >= 100, do: "100+"
  defp popularity_bucket(pop) when pop >= 50, do: "50-100"
  defp popularity_bucket(pop) when pop >= 20, do: "20-50"
  defp popularity_bucket(pop) when pop >= 10, do: "10-20"
  defp popularity_bucket(pop) when pop >= 5, do: "5-10"
  defp popularity_bucket(pop) when pop >= 1, do: "1-5"
  defp popularity_bucket(pop) when pop >= 0.5, do: "0.5-1"
  defp popularity_bucket(_), do: "<0.5"

  defp bucket_order("100+"), do: 0
  defp bucket_order("50-100"), do: 1
  defp bucket_order("20-50"), do: 2
  defp bucket_order("10-20"), do: 3
  defp bucket_order("5-10"), do: 4
  defp bucket_order("1-5"), do: 5
  defp bucket_order("0.5-1"), do: 6
  defp bucket_order("<0.5"), do: 7
end

defmodule Cinegraph.Imports.TMDbImporter do
  @moduledoc """
  Main module for orchestrating TMDB imports using Oban workers.
  """
  
  alias Cinegraph.Imports.ImportProgress
  alias Cinegraph.Workers.TMDbDiscoveryWorker
  require Logger
  
  @doc """
  Starts a full TMDB import, discovering all movies.
  
  ## Options
    - :sort_by - How to sort results (default: "popularity.desc")
    - :max_pages - Maximum pages to import (default: 500)
    - :start_year - Starting year for import
    - :end_year - Ending year for import
  """
  def start_full_import(opts \\ []) do
    Logger.info("Starting full TMDB import with options: #{inspect(opts)}")
    
    # Create import progress record
    {:ok, progress} = ImportProgress.start_import("full", %{
      metadata: %{
        "options" => Enum.into(opts, %{}),
        "started_by" => "system"
      }
    })
    
    # Start discovery with first page
    args = %{
      "page" => 1,
      "import_progress_id" => progress.id,
      "sort_by" => opts[:sort_by] || "popularity.desc",
      "max_pages" => opts[:max_pages] || 500
    }
    
    # Add date filters if provided
    args = 
      args
      |> maybe_add_arg("primary_release_year", opts[:year])
      |> maybe_add_arg("primary_release_date.gte", format_date(opts[:start_date]))
      |> maybe_add_arg("primary_release_date.lte", format_date(opts[:end_date]))
    
    # Queue the first discovery job
    case args
         |> TMDbDiscoveryWorker.new()
         |> Oban.insert() do
      {:ok, _job} ->
        {:ok, progress}
      {:error, reason} ->
        Logger.error("Failed to queue discovery job: #{inspect(reason)}")
        # Clean up the progress record
        ImportProgress.update(progress, %{status: "failed", error_message: inspect(reason)})
        {:error, reason}
    end
  end
  
  @doc """
  Starts a daily update import for new movies.
  """
  def start_daily_update do
    Logger.info("Starting daily TMDB update")
    
    # Get movies released in the last 7 days
    end_date = Date.utc_today()
    start_date = Date.add(end_date, -7)
    
    {:ok, progress} = ImportProgress.start_import("daily_update", %{
      metadata: %{
        "date_range" => "#{start_date} to #{end_date}"
      }
    })
    
    args = %{
      "page" => 1,
      "import_progress_id" => progress.id,
      "sort_by" => "release_date.desc",
      "primary_release_date.gte" => Date.to_string(start_date),
      "primary_release_date.lte" => Date.to_string(end_date),
      "max_pages" => 10  # Daily updates should be small
    }
    
    case args
         |> TMDbDiscoveryWorker.new()
         |> Oban.insert() do
      {:ok, _job} ->
        {:ok, progress}
      {:error, reason} ->
        Logger.error("Failed to queue daily update job: #{inspect(reason)}")
        ImportProgress.update(progress, %{status: "failed", error_message: inspect(reason)})
        {:error, reason}
    end
  end
  
  @doc """
  Starts an import by decade.
  """
  def start_decade_import(decade) when is_integer(decade) do
    # Validate decade is reasonable (e.g., 1900-2020)
    unless decade >= 1900 and decade <= 2020 and rem(decade, 10) == 0 do
      {:error, :invalid_decade}
    else
      Logger.info("Starting TMDB import for decade: #{decade}s")
      
      start_year = decade
      end_year = decade + 9
    
    {:ok, progress} = ImportProgress.start_import("backfill", %{
      metadata: %{
        "decade" => "#{decade}s",
        "year_range" => "#{start_year}-#{end_year}"
      }
    })
    
    # Process year by year to avoid huge result sets
    Enum.each(start_year..end_year, fn year ->
      args = %{
        "page" => 1,
        "import_progress_id" => progress.id,
        "sort_by" => "popularity.desc",
        "primary_release_year" => year,
        "max_pages" => 50
      }
      
        case args
             |> TMDbDiscoveryWorker.new(schedule_in: calculate_year_delay(year - start_year))
             |> Oban.insert() do
          {:ok, _job} ->
            :ok
          {:error, reason} ->
            Logger.error("Failed to queue job for year #{year}: #{inspect(reason)}")
        end
      end)
      
      {:ok, progress}
    end
  end
  
  @doc """
  Starts an import for popular movies only.
  """
  def start_popular_import(opts \\ []) do
    Logger.info("Starting popular movies import")
    
    {:ok, progress} = ImportProgress.start_import("discovery", %{
      metadata: %{
        "type" => "popular",
        "min_vote_count" => opts[:min_vote_count] || 100
      }
    })
    
    args = %{
      "page" => 1,
      "import_progress_id" => progress.id,
      "sort_by" => "popularity.desc",
      "vote_count.gte" => opts[:min_vote_count] || 100,
      "max_pages" => opts[:max_pages] || 100
    }
    
    case args
         |> TMDbDiscoveryWorker.new()
         |> Oban.insert() do
      {:ok, _job} ->
        {:ok, progress}
      {:error, reason} ->
        Logger.error("Failed to queue popular import job: #{inspect(reason)}")
        ImportProgress.update(progress, %{status: "failed", error_message: inspect(reason)})
        {:error, reason}
    end
  end
  
  @doc """
  Gets the current status of all imports.
  """
  def get_import_status do
    running = ImportProgress.get_running()
    
    Enum.map(running, fn progress ->
      %{
        id: progress.id,
        type: progress.import_type,
        status: progress.status,
        current_page: progress.current_page,
        total_pages: progress.total_pages,
        movies_found: progress.movies_found,
        movies_imported: progress.movies_imported,
        movies_failed: progress.movies_failed,
        started_at: progress.started_at,
        duration: calculate_duration(progress.started_at),
        rate: calculate_import_rate(progress)
      }
    end)
  end
  
  @doc """
  Pauses a running import.
  """
  def pause_import(progress_id) do
    case ImportProgress.get(progress_id) do
      nil ->
        {:error, :not_found}
      %{status: "running"} = progress ->
        ImportProgress.update(progress, %{status: "paused"})
      progress ->
        {:error, {:invalid_status, progress.status}}
    end
  end
  
  @doc """
  Resumes a paused import.
  """
  def resume_import(progress_id) do
    case ImportProgress.get(progress_id) do
      nil ->
        {:error, :not_found}
      %{status: "paused"} = progress ->
        # Update status
        {:ok, updated} = ImportProgress.update(progress, %{status: "running"})
        
        # Queue next page
        args = %{
          "page" => progress.current_page + 1,
          "import_progress_id" => progress.id
        }
        |> Map.merge(progress.metadata["options"] || %{})
        
        case %{args: args}
             |> TMDbDiscoveryWorker.new()
             |> Oban.insert() do
          {:ok, _job} ->
            {:ok, updated}
          {:error, reason} ->
            Logger.error("Failed to queue resume job: #{inspect(reason)}")
            ImportProgress.update(updated, %{status: "paused"})
            {:error, reason}
        end
      progress ->
        {:error, {:invalid_status, progress.status}}
    end
  end
  
  defp maybe_add_arg(args, _key, nil), do: args
  defp maybe_add_arg(args, key, value), do: Map.put(args, key, value)
  
  defp format_date(nil), do: nil
  defp format_date(%Date{} = date), do: Date.to_string(date)
  defp format_date(date_string) when is_binary(date_string), do: date_string
  
  defp calculate_duration(started_at) do
    DateTime.diff(DateTime.utc_now(), started_at)
  end
  
  defp calculate_import_rate(%{movies_imported: imported, started_at: started_at}) do
    duration_minutes = calculate_duration(started_at) / 60
    
    if duration_minutes > 0 do
      Float.round(imported / duration_minutes, 2)
    else
      0.0
    end
  end
  
  defp calculate_year_delay(year_offset) do
    # Start immediately, then add progressive delays
    # This prevents overwhelming the queue while respecting rate limits
    year_offset * 30 + :rand.uniform(30)
  end
end
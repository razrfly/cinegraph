defmodule CinegraphWeb.ImportDashboardLive do
  @moduledoc """
  Simplified import dashboard using state tracking.
  Shows real progress: TMDB Total - Our Total = Remaining
  """
  use CinegraphWeb, :live_view

  alias Cinegraph.Imports.TMDbImporter
  alias Cinegraph.Repo
  alias Cinegraph.Movies.MovieLists
  alias Cinegraph.Events
  alias Cinegraph.Metrics.ApiTracker
  alias Cinegraph.Cache.DashboardStats
  require Logger
  alias Cinegraph.Workers.{CanonicalImportOrchestrator, OscarImportWorker, DailyYearImportWorker}
  alias Cinegraph.Cultural
  alias Cinegraph.Repairs

  # 5 seconds
  @refresh_interval 5000

  @impl true
  def mount(_params, _session, socket) do
    # Subscribe to import progress updates
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Cinegraph.PubSub, "import_progress")
      # Subscribe to dashboard stats updates (async cache)
      Phoenix.PubSub.subscribe(Cinegraph.PubSub, "dashboard_stats")
    end

    socket =
      socket
      |> assign(:page_title, "Import Dashboard")
      |> assign(:refresh_timer, nil)
      |> assign(:canonical_import_running, false)
      |> assign(:canonical_import_progress, nil)
      |> assign(:oscar_import_running, false)
      |> assign(:oscar_import_progress, nil)
      |> assign(:festival_import_running, false)
      |> assign(:festival_import_progress, nil)
      |> assign(:canonical_lists, CanonicalImportOrchestrator.available_lists())
      |> assign(:oscar_decades, generate_oscar_decades())
      |> assign(:festival_list, generate_festival_list())
      |> assign(:festival_years, generate_festival_years())
      |> assign(:selected_year_range, nil)
      # Keep for backward compatibility
      |> assign(:venice_years, generate_venice_years())
      |> assign(:all_movie_lists, MovieLists.list_all_movie_lists())
      |> assign(:show_modal, false)
      |> assign(:editing_list, nil)
      |> assign(:api_metrics, %{})
      |> assign(:fallback_stats, %{})
      |> assign(:strategy_breakdown, [])
      |> assign(:import_metrics, [])
      |> assign(:year_progress, [])
      |> assign(:year_sync_health, nil)
      |> assign(:current_import_year, nil)
      |> assign(:year_import_running, false)
      |> assign(:data_issues, [])
      |> assign(:repair_progress, nil)
      |> load_data()
      |> schedule_refresh()

    {:ok, socket}
  end

  @impl true
  def handle_info(:refresh, socket) do
    socket =
      socket
      |> load_data()
      |> schedule_refresh()

    {:noreply, socket}
  end

  @impl true
  def handle_info(:stats_updated, socket) do
    # Stats cache has been updated, reload data
    {:noreply, load_data(socket)}
  end

  @impl true
  def handle_info({:canonical_progress, progress}, socket) do
    socket =
      case progress.status do
        :started ->
          assign(socket, :canonical_import_progress, progress.status)

        :completed ->
          # Invalidate cache on import completion
          DashboardStats.invalidate()

          # Build a more accurate completion message
          message =
            cond do
              # We have expected count to compare against
              Map.has_key?(progress, :expected_movies) && progress.expected_movies ->
                "Canonical import completed: #{progress.total_movies} of #{progress.expected_movies} movies imported"

              # We have queued info from the old worker
              Map.has_key?(progress, :movies_queued) && progress.movies_queued > 0 ->
                "Canonical import queued #{progress.movies_queued} movies for processing"

              # Default message with just the count
              true ->
                "Canonical import completed: #{progress.total_movies} movies in database"
            end

          socket
          |> put_flash(:info, message)
          |> assign(:canonical_import_running, false)
          |> assign(:canonical_import_progress, nil)
          |> load_data()

        _ ->
          assign(socket, :canonical_import_progress, format_canonical_progress(progress))
      end

    {:noreply, socket}
  end

  @impl true
  def handle_info({:oscar_progress, progress}, socket) do
    socket =
      case progress.status do
        :started ->
          assign(socket, :oscar_import_progress, progress.status)

        :completed ->
          # Invalidate cache on import completion
          DashboardStats.invalidate()

          message =
            case progress.type do
              :single ->
                "Oscar import completed for #{progress.year}: #{progress.total_nominees} nominees"

              :range ->
                "Oscar import completed for years #{progress.start_year}-#{progress.end_year}"

              :all ->
                "Oscar import completed for all years"
            end

          socket
          |> put_flash(:info, message)
          |> assign(:oscar_import_running, false)
          |> assign(:oscar_import_progress, nil)
          |> load_data()

        :queued ->
          assign(
            socket,
            :oscar_import_progress,
            "Queued #{progress.jobs_queued} Oscar import jobs"
          )

        _ ->
          assign(socket, :oscar_import_progress, format_oscar_progress(progress))
      end

    {:noreply, socket}
  end

  @impl true
  def handle_info({:year_import_complete, progress}, socket) do
    # Invalidate cache on import completion
    DashboardStats.invalidate()

    message =
      "Year #{progress.year} import complete! #{progress.completed} jobs completed, #{progress.movie_count} movies for that year."

    socket =
      socket
      |> put_flash(:info, message)
      |> assign(:year_import_running, false)
      |> load_data()

    {:noreply, socket}
  end

  @impl true
  def handle_info({:festival_progress, progress}, socket) do
    socket =
      case progress.status do
        :started ->
          assign(socket, :festival_import_progress, progress.status)

        :completed ->
          # Invalidate cache on import completion
          DashboardStats.invalidate()

          message =
            case progress.type do
              :single ->
                "Festival import completed for #{progress.festival} #{progress.year}: #{progress.nominations} nominations"

              :range ->
                "Festival import completed for #{progress.festival} years #{progress.start_year}-#{progress.end_year}"

              :all ->
                "Festival import completed for #{progress.festival}"
            end

          socket
          |> put_flash(:info, message)
          |> assign(:festival_import_running, false)
          |> assign(:festival_import_progress, nil)
          |> load_data()

        :queued ->
          assign(
            socket,
            :festival_import_progress,
            "Queued #{progress.jobs_queued} festival import jobs"
          )

        _ ->
          assign(socket, :festival_import_progress, format_festival_progress(progress))
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("start_year_import", %{"year" => year_str}, socket) do
    current_year = Date.utc_today().year

    case Integer.parse(year_str) do
      {year, _} when year >= 1888 ->
        if year <= current_year + 1 do
          case DailyYearImportWorker.import_year(year) do
            {:ok, _job} ->
              socket =
                socket
                |> put_flash(:info, "Started year import for #{year}")
                |> assign(:year_import_running, true)
                |> load_data()

              {:noreply, socket}

            {:error, reason} ->
              socket =
                put_flash(socket, :error, "Failed to start year import: #{inspect(reason)}")

              {:noreply, socket}
          end
        else
          socket = put_flash(socket, :error, "Invalid year - cannot be in the future")
          {:noreply, socket}
        end

      _ ->
        socket = put_flash(socket, :error, "Invalid year")
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("start_year_import", _params, socket) do
    # Start import for next year to import
    year = DailyYearImportWorker.get_next_year_to_import()

    case DailyYearImportWorker.import_year(year) do
      {:ok, _job} ->
        socket =
          socket
          |> put_flash(:info, "Started year import for #{year}")
          |> assign(:year_import_running, true)
          |> load_data()

        {:noreply, socket}

      {:error, reason} ->
        socket = put_flash(socket, :error, "Failed to start year import: #{inspect(reason)}")
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("start_full_import", _params, socket) do
    case TMDbImporter.start_full_import(pages: 100) do
      {:ok, info} ->
        socket =
          socket
          |> put_flash(
            :info,
            "Queued #{info.pages_queued} pages starting from page #{info.starting_page}"
          )
          |> load_data()

        {:noreply, socket}

      {:error, reason} ->
        socket =
          Phoenix.LiveView.put_flash(socket, :error, "Failed to start import: #{inspect(reason)}")

        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("start_daily_update", _params, socket) do
    case TMDbImporter.start_daily_update() do
      {:ok, _job} ->
        socket =
          socket
          |> put_flash(:info, "Started daily update for recent movies")
          |> load_data()

        {:noreply, socket}

      {:error, reason} ->
        socket =
          Phoenix.LiveView.put_flash(
            socket,
            :error,
            "Failed to start daily update: #{inspect(reason)}"
          )

        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("update_tmdb_total", _params, socket) do
    case TMDbImporter.update_tmdb_total() do
      {:ok, total} ->
        socket =
          socket
          |> Phoenix.LiveView.put_flash(
            :info,
            "Updated TMDB total: #{format_number(total)} movies"
          )
          |> load_data()

        {:noreply, socket}

      {:error, reason} ->
        socket =
          Phoenix.LiveView.put_flash(
            socket,
            :error,
            "Failed to update TMDB total: #{inspect(reason)}"
          )

        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("import_pages", %{"pages" => pages_str}, socket) do
    case Integer.parse(pages_str) do
      {pages, _} when pages > 0 ->
        case TMDbImporter.import_pages(pages) do
          {:ok, count} ->
            socket =
              socket
              |> put_flash(:info, "Queued #{count} pages for import")
              |> load_data()

            {:noreply, socket}

          {:error, reason} ->
            socket =
              Phoenix.LiveView.put_flash(
                socket,
                :error,
                "Failed to queue pages: #{inspect(reason)}"
              )

            {:noreply, socket}
        end

      _ ->
        socket = Phoenix.LiveView.put_flash(socket, :error, "Invalid number of pages")
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("import_canonical_list", %{"list_key" => "all"}, socket) do
    # Queue imports for all canonical lists from database
    jobs =
      MovieLists.all_as_config()
      |> Enum.map(fn {list_key, _config} ->
        %{
          "action" => "orchestrate_import",
          "list_key" => list_key
        }
        |> Cinegraph.Workers.CanonicalImportOrchestrator.new()
      end)

    # Insert all jobs
    case Oban.insert_all(jobs) do
      jobs_list when is_list(jobs_list) and length(jobs_list) > 0 ->
        socket =
          socket
          |> put_flash(:info, "Queued import for all #{length(jobs_list)} canonical lists")
          |> assign(:canonical_import_running, true)
          |> assign(:canonical_import_progress, "Starting import of all lists...")

        {:noreply, socket}

      _ ->
        socket = put_flash(socket, :error, "Failed to queue canonical imports")
        {:noreply, socket}
    end
  end

  def handle_event("import_canonical_list", %{"list_key" => list_key}, socket) do
    # Queue the canonical import orchestrator job
    %{
      "action" => "orchestrate_import",
      "list_key" => list_key
    }
    |> Cinegraph.Workers.CanonicalImportOrchestrator.new()
    |> Oban.insert()
    |> case do
      {:ok, _job} ->
        socket =
          socket
          |> put_flash(:info, "Queued canonical list import")
          |> assign(:canonical_import_running, true)
          |> assign(:canonical_import_progress, "Starting import...")

        {:noreply, socket}

      {:error, reason} ->
        socket = put_flash(socket, :error, "Failed to queue canonical import: #{inspect(reason)}")
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("import_oscars", %{"year_range" => year_range}, socket) do
    # Determine job args based on selection
    job_args =
      cond do
        year_range == "all" ->
          %{"action" => "import_all_years"}

        String.contains?(year_range, "-") ->
          [start_year_str, end_year_str] = String.split(year_range, "-")

          case {Integer.parse(start_year_str), Integer.parse(end_year_str)} do
            {{start_year, ""}, {end_year, ""}} ->
              %{"action" => "import_range", "start_year" => start_year, "end_year" => end_year}

            _ ->
              {:error, :invalid_year_range}
          end

        true ->
          case Integer.parse(year_range) do
            {year, ""} ->
              %{"action" => "import_single", "year" => year}

            _ ->
              {:error, :invalid_year}
          end
      end

    # Queue the Oscar import job
    case job_args do
      {:error, :invalid_year} ->
        socket = put_flash(socket, :error, "Invalid year format")
        {:noreply, socket}

      {:error, :invalid_year_range} ->
        socket = put_flash(socket, :error, "Invalid year range format")
        {:noreply, socket}

      _ ->
        job_args
        |> OscarImportWorker.new()
        |> Oban.insert()
        |> case do
          {:ok, _job} ->
            socket =
              socket
              |> put_flash(:info, "Queued Oscar import")
              |> assign(:oscar_import_running, true)
              |> assign(:oscar_import_progress, "Starting import...")

            {:noreply, socket}

          {:error, reason} ->
            socket = put_flash(socket, :error, "Failed to queue Oscar import: #{inspect(reason)}")
            {:noreply, socket}
        end
    end
  end

  @impl true
  def handle_event(
        "import_festival",
        %{"festival" => festival, "year_range" => year_range},
        socket
      ) do
    # Special handling for Academy Awards/Oscars - use the Oscar-specific scraper
    if festival == "oscars" do
      # Validate Oscar configuration exists for consistency
      case Events.get_active_by_source_key("oscars") do
        nil ->
          socket = put_flash(socket, :error, "Oscar configuration not found in database")
          {:noreply, socket}

        _event ->
          # Route to Oscar import handler
          handle_event("import_oscars", %{"year_range" => year_range}, socket)
      end
    else
      # Handle importing all festivals
      if festival == "all" do
        # Import all active festivals
        active_events = Events.list_active_events()

        results =
          Enum.map(active_events, fn event ->
            Logger.info("Processing import for festival: #{event.source_key} (#{event.name})")

            year_range_to_use =
              case year_range do
                "all" ->
                  get_festival_year_range(event)

                year_str ->
                  case Integer.parse(year_str) do
                    {year, ""} -> year
                    _ -> nil
                  end
              end

            Logger.info("Year range for #{event.source_key}: #{inspect(year_range_to_use)}")

            if year_range_to_use do
              # Special handling for Oscar imports - MUST be first to prevent falling through
              result =
                cond do
                  event.source_key == "oscars" and is_integer(year_range_to_use) ->
                    Logger.info("OSCAR PATH: Calling import_oscar_year(#{year_range_to_use})")
                    Cultural.import_oscar_year(year_range_to_use)

                  event.source_key == "oscars" and is_struct(year_range_to_use, Range) ->
                    Logger.info(
                      "OSCAR PATH: Calling import_oscar_years(#{inspect(year_range_to_use)})"
                    )

                    Cultural.import_oscar_years(year_range_to_use)

                  event.source_key == "oscars" ->
                    Logger.error(
                      "OSCAR PATH ERROR: Unexpected year_range type: #{inspect(year_range_to_use)}"
                    )

                    {:error, "Invalid year range for Oscars"}

                  event.source_key == "venice" and is_integer(year_range_to_use) ->
                    Logger.info("Calling import_venice_year(#{year_range_to_use})")
                    Cultural.import_venice_year(year_range_to_use)

                  event.source_key == "venice" ->
                    Logger.info("Calling import_venice_years(#{inspect(year_range_to_use)})")
                    Cultural.import_venice_years(year_range_to_use)

                  is_integer(year_range_to_use) and event.source_key != "oscars" ->
                    Logger.info(
                      "Calling import_festival(#{event.source_key}, #{year_range_to_use})"
                    )

                    Cultural.import_festival(event.source_key, year_range_to_use)

                  event.source_key != "oscars" ->
                    Logger.info(
                      "Calling import_festival_years(#{event.source_key}, #{inspect(year_range_to_use)})"
                    )

                    Cultural.import_festival_years(event.source_key, year_range_to_use)

                  true ->
                    Logger.error(
                      "UNHANDLED CASE: festival=#{event.source_key}, year_range=#{inspect(year_range_to_use)}"
                    )

                    {:error, "Unhandled import case"}
                end

              Logger.info("Import result for #{event.source_key}: #{inspect(result)}")
              result
            else
              {:error, "Invalid year"}
            end
          end)

        successful_imports = Enum.count(results, fn {status, _} -> status == :ok end)

        message =
          if year_range == "all" do
            "Queued #{successful_imports} festival imports for all available years"
          else
            "Queued #{successful_imports} festival imports for year #{year_range}"
          end

        socket =
          socket
          |> put_flash(:info, message)
          |> assign(:festival_import_running, true)
          |> assign(:festival_import_progress, "Starting imports...")

        {:noreply, socket}
      else
        # Validate festival exists in database before proceeding
        festival_event = Events.get_active_by_source_key(festival)

        result =
          case festival_event do
            nil ->
              {:error, "Festival not found in database"}

            _event ->
              case year_range do
                "all" ->
                  # Get year range from database event configuration or use default
                  year_range = get_festival_year_range(festival_event)
                  Cultural.import_festival_years(festival, year_range)

                year_str ->
                  case Integer.parse(year_str) do
                    {year, ""} when year > 1900 and year <= 2030 ->
                      # Use Venice-specific function for backward compatibility
                      if festival == "venice" do
                        Cultural.import_venice_year(year)
                      else
                        Cultural.import_festival(festival, year)
                      end

                    _ ->
                      {:error, "Invalid year format"}
                  end
              end
          end

        case result do
          {:ok, _import_result} ->
            festival_name = get_festival_display_name(festival)

            message =
              case year_range do
                "all" -> "Queued #{festival_name} import for all years (2020-2024)"
                _ -> "Queued #{festival_name} import for #{year_range}"
              end

            socket =
              socket
              |> put_flash(:info, message)
              |> assign(:festival_import_running, true)
              |> assign(:festival_import_progress, "Starting import...")

            {:noreply, socket}

          {:error, reason} ->
            socket =
              put_flash(socket, :error, "Failed to queue festival import: #{inspect(reason)}")

            {:noreply, socket}
        end
      end
    end
  end

  @impl true
  def handle_event("festival_selected", %{"festival" => festival}, socket) do
    # Update the festival_years assign based on the selected festival
    festival_years =
      if festival == "" do
        # No festival selected, show generic placeholder
        [%{value: "", label: "Select a festival first..."}]
      else
        generate_festival_years_for(festival)
      end

    socket =
      socket
      |> assign(:festival_years, festival_years)
      |> assign(:selected_year_range, nil)

    {:noreply, socket}
  end

  def handle_event("show_add_modal", _params, socket) do
    socket =
      socket
      |> assign(:show_modal, true)
      |> assign(:editing_list, nil)

    {:noreply, socket}
  end

  def handle_event("show_edit_modal", %{"id" => id}, socket) do
    list = MovieLists.get_movie_list!(String.to_integer(id))

    socket =
      socket
      |> assign(:show_modal, true)
      |> assign(:editing_list, list)

    {:noreply, socket}
  end

  @impl true
  def handle_event("hide_modal", _params, socket) do
    socket =
      socket
      |> assign(:show_modal, false)
      |> assign(:editing_list, nil)

    {:noreply, socket}
  end

  @impl true
  def handle_event("add_movie_list", params, socket) do
    # Auto-detect source type from URL
    source_type = detect_source_type(params["source_url"])

    attrs = %{
      source_url: params["source_url"],
      name: params["name"],
      source_key: params["source_key"],
      category: params["category"],
      description: params["description"],
      source_type: source_type,
      tracks_awards: params["tracks_awards"] == "on",
      active: true
    }

    case MovieLists.create_movie_list(attrs) do
      {:ok, list} ->
        socket =
          socket
          |> put_flash(:info, "List '#{list.name}' added successfully!")
          |> assign(:all_movie_lists, get_movie_list_with_real_counts())
          |> assign(:canonical_lists, CanonicalImportOrchestrator.available_lists())
          |> assign(:show_modal, false)

        {:noreply, socket}

      {:error, changeset} ->
        errors = format_changeset_errors(changeset)
        socket = put_flash(socket, :error, "Failed to add list: #{errors}")
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("update_movie_list", params, socket) do
    list = MovieLists.get_movie_list!(String.to_integer(params["list_id"]))

    # Auto-detect source type from URL
    source_type = detect_source_type(params["source_url"])

    attrs = %{
      source_url: params["source_url"],
      name: params["name"],
      category: params["category"],
      description: params["description"],
      source_type: source_type,
      tracks_awards: params["tracks_awards"] == "on"
    }

    case MovieLists.update_movie_list(list, attrs) do
      {:ok, updated_list} ->
        socket =
          socket
          |> put_flash(:info, "List '#{updated_list.name}' updated successfully!")
          |> assign(:all_movie_lists, get_movie_list_with_real_counts())
          |> assign(:canonical_lists, CanonicalImportOrchestrator.available_lists())
          |> assign(:show_modal, false)
          |> assign(:editing_list, nil)

        {:noreply, socket}

      {:error, changeset} ->
        errors = format_changeset_errors(changeset)
        socket = put_flash(socket, :error, "Failed to update list: #{errors}")
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("delete_list", %{"id" => id}, socket) do
    list = MovieLists.get_movie_list!(String.to_integer(id))

    case MovieLists.delete_movie_list(list) do
      {:ok, _deleted_list} ->
        socket =
          socket
          |> put_flash(:info, "List '#{list.name}' deleted successfully!")
          |> assign(:all_movie_lists, get_movie_list_with_real_counts())
          |> assign(:canonical_lists, CanonicalImportOrchestrator.available_lists())

        {:noreply, socket}

      {:error, _changeset} ->
        socket = put_flash(socket, :error, "Failed to delete list")
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("toggle_list_active", %{"id" => id}, socket) do
    list = MovieLists.get_movie_list!(String.to_integer(id))

    case MovieLists.update_movie_list(list, %{active: !list.active}) do
      {:ok, _updated_list} ->
        socket =
          socket
          |> put_flash(
            :info,
            "List #{if list.active, do: "disabled", else: "enabled"} successfully"
          )
          |> assign(:all_movie_lists, get_movie_list_with_real_counts())
          |> assign(:canonical_lists, CanonicalImportOrchestrator.available_lists())

        {:noreply, socket}

      {:error, _changeset} ->
        socket = put_flash(socket, :error, "Failed to update list")
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("start_repair", %{"type" => repair_type}, socket) do
    case Repairs.start_repair(repair_type) do
      {:ok, _job} ->
        socket =
          socket
          |> put_flash(:info, "Started repair job for #{repair_type}")
          |> assign(:repair_progress, %{type: repair_type, status: "Starting..."})
          |> load_data()

        {:noreply, socket}

      {:error, :already_running} ->
        socket = put_flash(socket, :info, "Repair job is already running")
        {:noreply, socket}

      {:error, :nothing_to_repair} ->
        socket = put_flash(socket, :info, "No records need repair")
        {:noreply, socket}

      {:error, reason} ->
        socket = put_flash(socket, :error, "Failed to start repair: #{inspect(reason)}")
        {:noreply, socket}
    end
  end

  defp get_festival_display_name(festival_key) do
    case Events.get_active_by_source_key(festival_key) do
      nil -> String.capitalize(festival_key)
      event -> event.name
    end
  end

  defp get_festival_year_range(festival_event) do
    # Extract year range from festival dates, or use sensible defaults
    current_year = Date.utc_today().year

    # Get available years from festival dates, or use default range
    case festival_event.metadata do
      %{"min_available_year" => min_year, "max_available_year" => max_year}
      when is_integer(min_year) and is_integer(max_year) ->
        min_year..max_year

      _ ->
        # Default range: 2020 to current year + 1
        2020..current_year
    end
  end

  defp format_changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
    |> Enum.map(fn {field, msgs} -> "#{field}: #{Enum.join(msgs, ", ")}" end)
    |> Enum.join("; ")
  end

  defp detect_source_type(url) do
    cond do
      String.contains?(url, "imdb.com") -> "imdb"
      String.contains?(url, "themoviedb.org") || String.contains?(url, "tmdb.org") -> "tmdb"
      String.contains?(url, "letterboxd.com") -> "letterboxd"
      true -> "custom"
    end
  end

  defp load_data(socket) do
    # Use cached stats to prevent timeout (Issue #421)
    # Cache has 60-second TTL, shared across all admin sessions
    # Returns defaults immediately if cache not ready (async computation)
    cached = DashboardStats.get_stats()

    # Handle nil/empty runtime_stats gracefully
    import_rate = get_in(cached, [:runtime_stats, :movies_per_minute]) || 0

    # Handle nil/empty year_progress gracefully
    year_progress =
      cached.year_progress || %{years: [], sync_health: %{}, current_year: nil, is_running: false}

    # Provide default db_stats with all required keys to prevent template errors
    default_db_stats = %{
      total_movies: 0,
      movies_with_tmdb: 0,
      movies_with_omdb: 0,
      canonical_movies: 0,
      festival_nominations: 0,
      festival_wins: 0,
      total_people: 0,
      directors_with_pqs: 0,
      actors_with_pqs: 0,
      total_credits: 0,
      total_genres: 0,
      total_keywords: 0,
      unique_collaborations: 0,
      multi_collaborations: 0
    }

    db_stats = Map.merge(default_db_stats, cached.db_stats || %{})

    socket
    |> assign(:progress, cached.progress || %{our_total: 0, tmdb_total: 0, remaining: 0})
    |> assign(:stats, db_stats)
    |> assign(:canonical_stats, cached.canonical_stats || [])
    |> assign(:oscar_stats, cached.oscar_stats || [])
    |> assign(:festival_stats, cached.festival_stats || [])
    |> assign(:queue_stats, cached.oban_stats || [])
    |> assign(:import_rate, import_rate)
    |> assign(:all_movie_lists, cached.movie_lists || [])
    |> assign(:canonical_lists, cached.canonical_lists || [])
    |> assign(:api_metrics, cached.api_metrics || %{})
    |> assign(:fallback_stats, cached.fallback_stats || %{})
    |> assign(:strategy_breakdown, cached.strategy_breakdown || [])
    |> assign(:import_metrics, cached.import_metrics || [])
    |> assign(:year_progress, year_progress.years || [])
    |> assign(:year_sync_health, year_progress.sync_health || %{})
    |> assign(:current_import_year, year_progress.current_year)
    |> assign(:year_import_running, year_progress.is_running || false)
    |> assign(:stats_loading, Map.get(cached, :loading, false))
    |> load_repair_data()
  end

  defp load_repair_data(socket) do
    # Load data issues and repair progress
    data_issues = Repairs.detect_all_issues()

    # Check for repair progress
    repair_progress =
      case Repairs.get_repair_progress("missing_director_credits") do
        nil ->
          nil

        job ->
          %{
            type: "missing_director_credits",
            status: format_repair_status(job),
            last_id: get_in(job.meta, ["last_id"])
          }
      end

    socket
    |> assign(:data_issues, data_issues)
    |> assign(:repair_progress, repair_progress)
  end

  defp format_repair_status(%{state: "executing", meta: meta}) do
    batch_success = meta["batch_success"] || 0
    "Processing... (#{batch_success} in current batch)"
  end

  defp format_repair_status(%{state: "available"}) do
    "Queued"
  end

  defp format_repair_status(%{state: "scheduled"}) do
    "Scheduled"
  end

  defp format_repair_status(_) do
    "Unknown"
  end

  defp schedule_refresh(socket) do
    if connected?(socket) do
      timer = Process.send_after(self(), :refresh, @refresh_interval)
      assign(socket, :refresh_timer, timer)
    else
      socket
    end
  end

  @doc """
  Formats a number with thousand separators.
  """
  def format_number(nil), do: "0"

  def format_number(num) when is_integer(num) do
    num
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  def format_number(num) when is_float(num) do
    format_number(round(num))
  end

  @doc """
  Estimates time to completion based on current rate.
  """
  def estimate_completion_time(remaining, rate) when rate > 0 do
    minutes = remaining / rate
    hours = minutes / 60
    days = hours / 24

    cond do
      days >= 1 -> "~#{Float.round(days, 1)} days"
      hours >= 1 -> "~#{Float.round(hours, 1)} hours"
      true -> "~#{Float.round(minutes, 0)} minutes"
    end
  end

  def estimate_completion_time(_, _), do: "Unknown"

  defp get_movie_list_with_real_counts do
    # Get all movie lists with real database counts instead of last_movie_count
    MovieLists.list_all_movie_lists()
    |> Enum.map(fn list ->
      # Get real count from database
      real_count =
        case Repo.query("SELECT COUNT(*) FROM movies WHERE canonical_sources ? $1", [
               list.source_key
             ]) do
          {:ok, %{rows: [[count]]}} -> count
          _ -> 0
        end

      # Add real count to the list struct
      Map.put(list, :real_movie_count, real_count)
    end)
  end

  @doc """
  Formats queue names for display.
  """
  def format_queue_name(:tmdb), do: "TMDb"
  def format_queue_name(:omdb), do: "OMDb"
  def format_queue_name(:collaboration), do: "Collaboration"
  def format_queue_name(:scraping), do: "Scraping"
  def format_queue_name(:metrics), do: "Metrics"
  def format_queue_name(:maintenance), do: "Maintenance"

  def format_queue_name(queue) when is_atom(queue),
    do: queue |> to_string() |> String.capitalize()

  def format_queue_name(queue), do: String.capitalize(queue)

  defp format_canonical_progress(progress) do
    case progress do
      %{status: status} when is_binary(status) ->
        status

      %{progress_percent: percent} ->
        "Processing pages... #{percent}% complete"

      %{pages_queued: pages, total_pages: total} ->
        "Queued #{pages} of #{total} page jobs for processing"

      %{pages_queued: pages} ->
        "Queued #{pages} page jobs for processing"

      %{list_name: name, expected_count: count} when count ->
        "Importing #{name} (#{count} movies expected)..."

      %{list_name: name} ->
        "Importing #{name}..."

      _ ->
        "Processing canonical list..."
    end
  end

  defp format_oscar_progress(progress) do
    case progress do
      %{status: status} when is_binary(status) -> status
      %{year: year} -> "Importing Oscar data for #{year}..."
      _ -> "Processing Oscar import..."
    end
  end

  defp format_festival_progress(progress) do
    case progress do
      %{status: status} when is_binary(status) -> status
      %{year: year, festival: festival} -> "Importing #{festival} data for #{year}..."
      %{festival: festival} -> "Processing #{festival} import..."
      _ -> "Processing festival import..."
    end
  end

  defp generate_festival_list do
    # Get all active festival events from the database
    active_events = Events.list_active_events()

    festival_options =
      active_events
      |> Enum.map(fn event ->
        %{
          value: event.source_key,
          label: event.name
        }
      end)
      |> Enum.sort_by(& &1.label)

    # Add "All Festivals" option at the beginning if there are multiple festivals
    if length(festival_options) > 1 do
      [%{value: "all", label: "All Festivals"} | festival_options]
    else
      festival_options
    end
  end

  defp generate_oscar_decades do
    current_year = Date.utc_today().year
    current_decade_start = div(current_year, 10) * 10
    # First practical Oscar ceremony data available
    start_decade = 1930

    # Generate decades from start_decade to current_decade in reverse order (newest first)
    current_decade_start
    |> then(fn decade -> decade..start_decade//-10 end)
    |> Enum.map(fn decade_start ->
      decade_end = min(decade_start + 9, current_year)
      decade_name = "#{decade_start}s"

      %{
        value: "#{decade_start}-#{decade_end}",
        label: "#{decade_name} (#{decade_start}-#{decade_end})"
      }
    end)
  end

  defp generate_festival_years do
    # Generate a default year range using current year
    current_year = Date.utc_today().year

    # Default range: Show 5 years back and current year
    min_year = current_year - 5
    max_year = current_year

    # Generate years in reverse order (newest first)
    festival_years = max_year..min_year//-1

    years_list =
      Enum.map(festival_years, fn year ->
        %{
          value: to_string(year),
          label: to_string(year)
        }
      end)

    # Add placeholder at top - will be replaced dynamically
    [%{value: "", label: "Select a festival first..."} | years_list]
  end

  defp generate_festival_years_for(festival_key) do
    # Special case for "All festivals" option
    if festival_key == "all" do
      current_year = Date.utc_today().year

      # Return practical test options for "All festivals"
      [
        %{value: to_string(current_year), label: "#{current_year} (Current Year)"},
        %{value: to_string(current_year - 1), label: "#{current_year - 1} (Previous Year)"},
        %{value: to_string(current_year - 2), label: "#{current_year - 2}"},
        %{value: "2020-2024", label: "2020-2024 (Test Range)"},
        %{value: "2015-2024", label: "2015-2024 (Extended Range)"}
      ]
    else
      # Get the specific festival event
      festival_event = Events.get_active_by_source_key(festival_key)

      if festival_event do
        current_year = Date.utc_today().year

        # Use festival-specific min/max years
        min_year = festival_event.min_available_year || festival_event.founded_year || 2020
        max_year = min(festival_event.max_available_year || current_year, current_year)

        # For future festivals that haven't occurred yet
        if min_year > current_year do
          [%{value: "", label: "Festival not yet available"}]
        else
          # Generate years in reverse order (newest first)
          festival_years = max_year..min_year//-1

          years_list =
            Enum.map(festival_years, fn year ->
              %{
                value: to_string(year),
                label: to_string(year)
              }
            end)

          # Add "All Years" option at the top with the actual range
          [%{value: "all", label: "All Available Years (#{min_year}-#{max_year})"} | years_list]
        end
      else
        # Fallback if festival not found
        [%{value: "", label: "Festival configuration not found"}]
      end
    end
  end

  # Keep the old function for backward compatibility with the template
  defp generate_venice_years do
    generate_festival_years()
  end
end

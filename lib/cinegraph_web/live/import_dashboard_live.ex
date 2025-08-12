defmodule CinegraphWeb.ImportDashboardLive do
  @moduledoc """
  Simplified import dashboard using state tracking.
  Shows real progress: TMDB Total - Our Total = Remaining
  """
  use CinegraphWeb, :live_view

  alias Cinegraph.Imports.TMDbImporter
  alias Cinegraph.Repo
  alias Cinegraph.Movies.{Movie, MovieLists}
  alias Cinegraph.Events
  alias Cinegraph.Metrics.ApiTracker
  require Logger
  alias Cinegraph.Workers.{CanonicalImportOrchestrator, OscarImportWorker}
  alias Cinegraph.Cultural
  import Ecto.Query

  # 5 seconds
  @refresh_interval 5000

  @impl true
  def mount(_params, _session, socket) do
    # Subscribe to import progress updates
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Cinegraph.PubSub, "import_progress")
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
  def handle_info({:canonical_progress, progress}, socket) do
    socket =
      case progress.status do
        :started ->
          assign(socket, :canonical_import_progress, progress.status)

        :completed ->
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
  def handle_info({:festival_progress, progress}, socket) do
    socket =
      case progress.status do
        :started ->
          assign(socket, :festival_import_progress, progress.status)

        :completed ->
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
    # Get progress
    progress = TMDbImporter.get_progress()

    # Get database stats
    stats = %{
      total_movies: Repo.aggregate(Movie, :count),
      movies_with_tmdb: Repo.aggregate(from(m in Movie, where: not is_nil(m.tmdb_data)), :count),
      movies_with_omdb: Repo.aggregate(from(m in Movie, where: not is_nil(m.omdb_data)), :count),
      canonical_movies: get_canonical_movies_count(),
      oscar_movies: get_oscar_movies_count(),
      venice_movies: get_venice_movies_count(),
      total_people: Repo.aggregate(Cinegraph.Movies.Person, :count),
      total_credits: Repo.aggregate(Cinegraph.Movies.Credit, :count),
      total_genres: Repo.aggregate(Cinegraph.Movies.Genre, :count),
      total_keywords: Repo.aggregate(Cinegraph.Movies.Keyword, :count),
      unique_collaborations: Repo.aggregate(Cinegraph.Collaborations.Collaboration, :count),
      multi_collaborations:
        Repo.aggregate(
          from(c in Cinegraph.Collaborations.Collaboration, where: c.collaboration_count > 1),
          :count
        )
    }

    # Get canonical list stats
    canonical_stats = get_canonical_list_stats()

    # Get Oscar statistics
    oscar_stats = get_oscar_stats()

    # Get Festival statistics  
    festival_stats = get_festival_stats()

    # Get Oban queue stats
    queue_stats = get_oban_stats()

    # Get runtime stats from ImportStats
    runtime_stats = Cinegraph.Imports.ImportStats.get_stats()

    # Get API metrics
    api_metrics = get_api_metrics()
    fallback_stats = get_fallback_stats()
    strategy_breakdown = get_strategy_breakdown()

    socket
    |> assign(:progress, progress)
    |> assign(:stats, stats)
    |> assign(:canonical_stats, canonical_stats)
    |> assign(:oscar_stats, oscar_stats)
    |> assign(:festival_stats, festival_stats)
    |> assign(:queue_stats, queue_stats)
    |> assign(:import_rate, runtime_stats.movies_per_minute)
    |> assign(:all_movie_lists, get_movie_list_with_real_counts())
    |> assign(:canonical_lists, CanonicalImportOrchestrator.available_lists())
    |> assign(:api_metrics, api_metrics)
    |> assign(:fallback_stats, fallback_stats)
    |> assign(:strategy_breakdown, strategy_breakdown)
  end

  defp get_canonical_movies_count do
    # Get all active canonical source keys dynamically from database
    active_source_keys = MovieLists.get_active_source_keys()

    if length(active_source_keys) > 0 do
      Repo.aggregate(
        from(m in Movie, where: fragment("? \\?| ?", m.canonical_sources, ^active_source_keys)),
        :count
      )
    else
      0
    end
  end

  defp get_oscar_movies_count do
    # Count movies that have Oscar nominations in the festival_nominations table
    oscar_org = Cinegraph.Festivals.get_or_create_oscar_organization()

    if oscar_org && oscar_org.id do
      # Count distinct movies with Oscar nominations
      Repo.one(
        from n in Cinegraph.Festivals.FestivalNomination,
          join: c in Cinegraph.Festivals.FestivalCeremony,
          on: n.ceremony_id == c.id,
          where: c.organization_id == ^oscar_org.id,
          select: count(n.movie_id, :distinct)
      ) || 0
    else
      Logger.error("Failed to get or create Oscar organization for dashboard stats")
      0
    end
  end

  defp get_venice_movies_count do
    # Count movies that have Venice nominations in the festival_nominations table
    venice_org = Cinegraph.Festivals.get_organization_by_abbreviation("VIFF")

    if venice_org && venice_org.id do
      # Count distinct movies with Venice nominations
      Repo.one(
        from n in Cinegraph.Festivals.FestivalNomination,
          join: c in Cinegraph.Festivals.FestivalCeremony,
          on: n.ceremony_id == c.id,
          where: c.organization_id == ^venice_org.id,
          select: count(n.movie_id, :distinct)
      ) || 0
    else
      0
    end
  end

  defp get_canonical_list_stats do
    # Get all canonical lists from database and their counts
    MovieLists.all_as_config()
    |> Enum.map(fn {list_key, config} ->
      # Use raw SQL to avoid Ecto escaping issues with the ? operator
      {:ok, %{rows: [[count]]}} =
        Repo.query(
          "SELECT COUNT(*) FROM movies WHERE canonical_sources ? $1",
          [list_key]
        )

      # Get expected count from database metadata if available
      expected_count =
        case MovieLists.get_active_by_source_key(list_key) do
          nil -> nil
          list -> list.metadata["expected_movie_count"]
        end

      %{
        key: list_key,
        name: config.name,
        count: count,
        expected_count: expected_count
      }
    end)
    # Sort by count descending
    |> Enum.sort_by(& &1.count, :desc)
  end

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

  defp get_oscar_stats do
    # Get the Oscar organization first
    oscar_org = Cinegraph.Festivals.get_or_create_oscar_organization()

    if oscar_org && oscar_org.id do
      # Get ceremony years and their nomination/win counts from festival tables
      ceremony_stats =
        Repo.all(
          from fc in Cinegraph.Festivals.FestivalCeremony,
            left_join: nom in Cinegraph.Festivals.FestivalNomination,
            on: nom.ceremony_id == fc.id,
            where: fc.organization_id == ^oscar_org.id,
            group_by: [fc.year, fc.id],
            select:
              {fc.year, count(nom.id), sum(fragment("CASE WHEN ? THEN 1 ELSE 0 END", nom.won))},
            order_by: [desc: fc.year]
        )

      # Calculate totals (ceremony_stats now returns tuples: {year, nominations, wins})
      total_nominations =
        Enum.sum(Enum.map(ceremony_stats, fn {_year, nominations, _wins} -> nominations end))

      total_wins =
        Enum.sum(Enum.map(ceremony_stats, fn {_year, _nominations, wins} -> wins || 0 end))

      total_ceremonies = length(ceremony_stats)
      # Count Oscar categories from festival_categories table
      total_categories =
        Repo.aggregate(
          from(c in Cinegraph.Festivals.FestivalCategory,
            where: c.organization_id == ^oscar_org.id
          ),
          :count
        )

      # Calculate People Nominations (nominations in categories that track people)
      people_nominations_query =
        from nom in Cinegraph.Festivals.FestivalNomination,
          join: fc in Cinegraph.Festivals.FestivalCategory,
          on: nom.category_id == fc.id,
          join: cer in Cinegraph.Festivals.FestivalCeremony,
          on: nom.ceremony_id == cer.id,
          where: fc.tracks_person == true and cer.organization_id == ^oscar_org.id,
          select: count(nom.id)

      people_nominations = Repo.one(people_nominations_query) || 0

      # Calculate People Nominations with names in details
      people_nominations_with_names =
        Repo.one(
          from nom in Cinegraph.Festivals.FestivalNomination,
            join: fc in Cinegraph.Festivals.FestivalCategory,
            on: nom.category_id == fc.id,
            join: cer in Cinegraph.Festivals.FestivalCeremony,
            on: nom.ceremony_id == cer.id,
            where:
              fc.tracks_person == true and
                cer.organization_id == ^oscar_org.id and
                not is_nil(fragment("? ->> 'nominee_names'", nom.details)) and
                fragment("? ->> 'nominee_names'", nom.details) != "",
            select: count(nom.id)
        ) || 0

      # Format People Nominations display
      people_nominations_display =
        if people_nominations == people_nominations_with_names do
          "#{format_number(people_nominations)} ✅"
        else
          "#{format_number(people_nominations_with_names)}/#{format_number(people_nominations)} ⚠️"
        end

      # Build stats list
      base_stats = [
        %{label: "Ceremonies Imported", value: "#{total_ceremonies} (2016-2024)"},
        %{label: "Total Nominations", value: format_number(total_nominations)},
        %{label: "Total Wins", value: format_number(total_wins)},
        %{label: "Categories", value: format_number(total_categories)},
        %{label: "People Nominations", value: people_nominations_display}
      ]

      # Add year-by-year breakdown
      year_stats =
        ceremony_stats
        # Only show years with data
        |> Enum.filter(fn {_year, nominations, _wins} -> nominations > 0 end)
        |> Enum.map(fn {year, nominations, wins} ->
          %{
            label: "#{year} Wins",
            value: "#{wins || 0}/#{nominations}"
          }
        end)

      base_stats ++ year_stats
    else
      Logger.error("Failed to get or create Oscar organization for dashboard stats")
      []
    end
  end

  defp get_oban_stats do
    queues = [
      :tmdb_discovery,
      :tmdb_details,
      :omdb_enrichment,
      :collaboration,
      :imdb_scraping,
      :oscar_imports,
      :festival_import
    ]

    Enum.map(queues, fn queue ->
      available =
        Repo.aggregate(
          from(j in Oban.Job, where: j.queue == ^to_string(queue) and j.state == "available"),
          :count
        )

      executing =
        Repo.aggregate(
          from(j in Oban.Job, where: j.queue == ^to_string(queue) and j.state == "executing"),
          :count
        )

      completed =
        Repo.aggregate(
          from(j in Oban.Job, where: j.queue == ^to_string(queue) and j.state == "completed"),
          :count
        )

      %{
        name: queue,
        available: available,
        executing: executing,
        completed: completed
      }
    end)
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

  defp get_api_metrics do
    # Get metrics for last 24 hours
    ApiTracker.get_all_stats(24)
    |> Enum.group_by(& &1.source)
    |> Enum.map(fn {source, operations} ->
      total_calls = Enum.sum(Enum.map(operations, & &1.total))
      total_successful = Enum.sum(Enum.map(operations, & (&1.successful || 0)))
      avg_response_time = 
        if total_calls > 0 do
          total_response_time = Enum.sum(Enum.map(operations, fn op -> 
            avg_time = case op.avg_response_time do
              %Decimal{} = decimal -> Decimal.to_float(decimal)
              nil -> 0
              value -> value
            end
            avg_time * op.total 
          end))
          Float.round(total_response_time / total_calls, 0)
        else
          0
        end
      
      success_rate = if total_calls > 0, do: Float.round(total_successful / total_calls * 100, 1), else: 0.0
      
      {source, %{
        total_calls: total_calls,
        success_rate: success_rate,
        avg_response_time: avg_response_time,
        operations: operations
      }}
    end)
    |> Enum.into(%{})
  end

  defp get_fallback_stats do
    ApiTracker.get_tmdb_fallback_stats(24)
    |> Enum.map(fn stat ->
      {stat.level, %{
        total: stat.total,
        successful: stat.successful || 0,
        success_rate: stat.success_rate || 0.0,
        avg_confidence: Float.round(stat.avg_confidence || 0, 2)
      }}
    end)
    |> Enum.into(%{})
  end

  defp get_strategy_breakdown do
    ApiTracker.get_tmdb_strategy_breakdown(24)
  end

  @doc """
  Formats queue names for display.
  """
  def format_queue_name(:tmdb_discovery), do: "TMDb Discovery"
  def format_queue_name(:tmdb_details), do: "TMDb Details"
  def format_queue_name(:omdb_enrichment), do: "OMDb Enrichment"
  def format_queue_name(:collaboration), do: "Collaboration"
  def format_queue_name(:imdb_scraping), do: "IMDb Scraping"
  def format_queue_name(:oscar_imports), do: "Oscar Imports"
  def format_queue_name(:festival_import), do: "Festival Imports"

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

  defp get_festival_stats do
    # Get all festival organizations except AMPAS (shown in Academy Awards section)
    festival_orgs =
      Repo.all(
        from fo in Cinegraph.Festivals.FestivalOrganization,
          where: fo.abbreviation != "AMPAS",
          select: fo
      )

    # Collect stats for all festivals
    all_stats =
      festival_orgs
      |> Enum.flat_map(fn org ->
        # Get ceremony years and their nomination/win counts from festival tables
        ceremony_stats =
          Repo.all(
            from fc in Cinegraph.Festivals.FestivalCeremony,
              left_join: nom in Cinegraph.Festivals.FestivalNomination,
              on: nom.ceremony_id == fc.id,
              where: fc.organization_id == ^org.id,
              group_by: [fc.year, fc.id],
              select:
                {fc.year, count(nom.id), sum(fragment("CASE WHEN ? THEN 1 ELSE 0 END", nom.won))},
              order_by: [desc: fc.year]
          )

        if length(ceremony_stats) > 0 do
          # Calculate totals
          total_nominations =
            Enum.sum(Enum.map(ceremony_stats, fn {_year, nominations, _wins} -> nominations end))

          total_wins =
            Enum.sum(Enum.map(ceremony_stats, fn {_year, _nominations, wins} -> wins || 0 end))

          total_ceremonies = length(ceremony_stats)

          # Count categories
          total_categories =
            Repo.aggregate(
              from(c in Cinegraph.Festivals.FestivalCategory,
                where: c.organization_id == ^org.id
              ),
              :count
            )

          # Get festival display name
          festival_name =
            case org.abbreviation do
              "VIFF" -> "Venice"
              "CFF" -> "Cannes"
              "BIFF" -> "Berlin"
              _ -> org.name
            end

          # Build stats list for this festival
          base_stats = [
            %{label: "#{festival_name} Ceremonies", value: "#{total_ceremonies}"},
            %{label: "#{festival_name} Nominations", value: format_number(total_nominations)},
            %{label: "#{festival_name} Wins", value: format_number(total_wins)},
            %{label: "#{festival_name} Categories", value: format_number(total_categories)}
          ]

          # Add year-by-year breakdown if we have data
          year_stats =
            ceremony_stats
            |> Enum.filter(fn {_year, nominations, _wins} -> nominations > 0 end)
            # Show last 3 years only per festival
            |> Enum.take(3)
            |> Enum.map(fn {year, nominations, wins} ->
              %{
                label: "#{festival_name} #{year}",
                value: "#{wins || 0}/#{nominations}"
              }
            end)

          base_stats ++ year_stats
        else
          []
        end
      end)

    if length(all_stats) > 0 do
      all_stats
    else
      []
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

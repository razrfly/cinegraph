defmodule Cinegraph.Events do
  @moduledoc """
  The Events context for managing festival events and dates.
  This provides a database-driven approach to festival management.
  """

  import Ecto.Query, warn: false
  alias Cinegraph.Repo

  alias Cinegraph.Events.{FestivalEvent, FestivalDate}

  # ========================================
  # FESTIVAL EVENTS
  # ========================================

  @doc """
  Returns the list of all festival events.
  """
  def list_festival_events do
    from(e in FestivalEvent,
      order_by: [desc: e.import_priority, asc: e.typical_start_month]
    )
    |> Repo.all()
  end

  @doc """
  Returns the list of active festival events.
  """
  def list_active_events do
    from(e in FestivalEvent,
      where: e.active == true,
      order_by: [desc: e.import_priority, asc: e.typical_start_month]
    )
    |> Repo.all()
  end

  @doc """
  Gets a single festival event by source key.
  """
  def get_by_source_key(source_key) do
    Repo.get_by(FestivalEvent, source_key: source_key)
  end

  @doc """
  Gets a festival event by abbreviation.
  """
  def get_by_abbreviation(abbreviation) do
    Repo.get_by(FestivalEvent, abbreviation: abbreviation)
  end

  @doc """
  Gets an active festival event by source key.
  """
  def get_active_by_source_key(source_key) do
    from(e in FestivalEvent,
      where: e.source_key == ^source_key and e.active == true
    )
    |> Repo.one()
  end

  @doc """
  Creates a festival event.
  """
  def create_festival_event(attrs \\ %{}) do
    %FestivalEvent{}
    |> FestivalEvent.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a festival event.
  """
  def update_festival_event(%FestivalEvent{} = event, attrs) do
    event
    |> FestivalEvent.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Updates import statistics for a festival event.
  """
  def update_import_stats(%FestivalEvent{} = event, success \\ true, error \\ nil) do
    attrs = %{
      last_successful_import:
        if(success, do: DateTime.utc_now(), else: event.last_successful_import),
      total_successful_imports:
        if(success,
          do: (event.total_successful_imports || 0) + 1,
          else: event.total_successful_imports
        ),
      last_error: error
    }

    update_festival_event(event, attrs)
  end

  @doc """
  Returns festivals that should be imported based on date awareness.
  """
  def get_importable_festivals(current_date \\ Date.utc_today()) do
    from(e in FestivalEvent,
      left_join: d in FestivalDate,
      on: d.festival_event_id == e.id and d.year == ^current_date.year,
      where: e.active == true,
      where: is_nil(d.status) or d.status in ["completed"],
      order_by: [desc: e.import_priority],
      preload: [dates: d]
    )
    |> Repo.all()
  end

  # ========================================
  # FESTIVAL DATES
  # ========================================

  @doc """
  Gets festival date by event and year.
  """
  def get_festival_date(event_id, year) do
    Repo.get_by(FestivalDate, festival_event_id: event_id, year: year)
  end

  @doc """
  Creates or updates a festival date.
  """
  def upsert_festival_date(attrs) do
    %FestivalDate{}
    |> FestivalDate.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace_all_except, [:id, :inserted_at]},
      conflict_target: [:festival_event_id, :year]
    )
  end

  @doc """
  Determines if a festival should be imported for a given year.
  """
  def should_import_festival?(source_key, year) do
    event = get_active_by_source_key(source_key)

    if event do
      case get_festival_date(event.id, year) do
        # No date info, assume importable
        nil -> true
        %{status: "completed"} -> true
        %{status: "cancelled"} -> false
        %{status: "upcoming"} -> false
        %{status: "in_progress"} -> false
      end
    else
      # Event not configured
      false
    end
  end
end

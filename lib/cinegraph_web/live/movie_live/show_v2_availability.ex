defmodule CinegraphWeb.MovieLive.ShowV2Availability do
  @moduledoc """
  Availability assigns and rendering for the movie show V2 page.
  """

  use CinegraphWeb, :html

  alias Cinegraph.Movies.Availability

  @doc """
  Assigns region-aware watch availability data for the movie show page.
  """
  def assign_availability(socket, movie, region) do
    assign(socket, availability_assigns(movie, region))
  end

  @doc """
  Builds the assigns consumed by the Where to Watch component.
  """
  def availability_assigns(movie, region) do
    regions = Availability.available_regions(movie.id)
    region = choose_availability_region(region, regions)
    region_options = Availability.region_options(regions)
    region_label = region_options |> Enum.into(%{}) |> Map.get(region, region)

    %{
      availability_region: region,
      availability_region_label: region_label,
      availability_regions: regions,
      availability_region_options: region_options,
      availability_groups: Availability.list_movie_availability(movie.id, region),
      availability_freshness: Availability.availability_freshness(movie.id, region),
      availability_refresh_queued: Availability.availability_refresh_queued?(movie.id, region)
    }
  end

  @doc """
  Renders the Where to Watch section with region selection and provider groups.
  """
  def where_to_watch(assigns) do
    ~H"""
    <section id="watch">
      <div class="flex items-start justify-between gap-4 mb-5 flex-wrap">
        <div>
          <h2 class="font-display italic text-[28px] sm:text-[32px] tracking-[-.01em] text-mist-950">
            Where to Watch
          </h2>
          <p class="mt-1 text-[12.5px] text-mist-600">
            {availability_status_copy(@availability_freshness, @availability_region_label)}
            <span :if={@availability_refresh_queued} class="ml-1 font-semibold text-mist-900">
              Refresh queued.
            </span>
          </p>
        </div>

        <form
          :if={length(@availability_regions) > 1}
          id="availability-region-form"
          phx-change="change_availability_region"
          class="w-full sm:w-auto sm:min-w-[240px] shrink-0"
        >
          <label for="availability-region-select" class="sr-only">Region</label>
          <select
            id="availability-region-select"
            name="region"
            class="w-full min-w-[240px] rounded-full border border-mist-950/10 bg-mist-50 py-2 pl-3.5 pr-10 text-[13px] font-semibold text-mist-900"
          >
            <option
              :for={{region, label} <- @availability_region_options}
              value={region}
              selected={region == @availability_region}
            >
              {label}
            </option>
          </select>
        </form>
      </div>

      <div
        :if={availability_has_rows?(@availability_groups)}
        class="space-y-5 bg-mist-50 border border-mist-950/10 rounded-lg p-5"
      >
        <div
          :for={type <- availability_group_order()}
          :if={Map.get(@availability_groups, type, []) != []}
        >
          <h3 class="text-[10.5px] font-semibold text-mist-500 tracking-[.06em] uppercase mb-3">
            {availability_group_label(type)}
          </h3>
          <div class="flex flex-wrap gap-2.5">
            <div
              :for={availability <- Map.get(@availability_groups, type, [])}
              class="inline-flex items-center gap-2 rounded-full bg-white border border-mist-950/10 px-2.5 py-1.5 shadow-[0_1px_4px_rgba(20,18,15,.03)]"
            >
              <% provider_name = availability_provider_name(availability) %>
              <img
                :if={availability_provider_logo(availability)}
                src={availability_provider_logo(availability)}
                alt=""
                class="w-6 h-6 rounded-full object-cover bg-mist-100"
              />
              <span
                :if={!availability_provider_logo(availability)}
                class="w-6 h-6 rounded-full bg-mist-950 text-white grid place-items-center text-[9px] font-semibold"
              >
                {availability_initials(provider_name)}
              </span>
              <span class="text-[12.5px] font-semibold text-mist-900">{provider_name}</span>
            </div>
          </div>
        </div>
      </div>

      <div
        :if={!availability_has_rows?(@availability_groups)}
        class="bg-mist-50 border border-mist-950/10 rounded-lg p-5 text-[13px] text-mist-700"
      >
        {availability_status_copy(@availability_freshness, @availability_region_label)}
      </div>

      <p class="mt-3 text-[11.5px] text-mist-500">
        Availability data from TMDb. Streaming availability changes often and may vary by region.
      </p>
    </section>
    """
  end

  defp choose_availability_region(region, regions) when is_binary(region) do
    normalized = region |> String.trim() |> String.upcase()

    cond do
      normalized in regions -> normalized
      Availability.default_region() in regions -> Availability.default_region()
      true -> Availability.default_region()
    end
  end

  defp choose_availability_region(region_candidates, regions) when is_list(region_candidates) do
    region =
      region_candidates
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&(String.trim(&1) |> String.upcase()))
      |> Enum.find(&(&1 in regions))

    cond do
      is_binary(region) -> region
      Availability.default_region() in regions -> Availability.default_region()
      regions != [] -> List.first(regions)
      true -> Availability.default_region()
    end
  end

  defp choose_availability_region(_region, regions) do
    cond do
      Availability.default_region() in regions -> Availability.default_region()
      regions != [] -> List.first(regions)
      true -> Availability.default_region()
    end
  end

  defp availability_group_label("flatrate"), do: "Streaming"
  defp availability_group_label("free"), do: "Free"
  defp availability_group_label("ads"), do: "Free with ads"
  defp availability_group_label("rent"), do: "Rent"
  defp availability_group_label("buy"), do: "Buy"

  defp availability_group_label(type) do
    type |> to_string() |> String.replace("_", " ") |> String.capitalize()
  end

  defp availability_group_order, do: ~w(flatrate free ads rent buy)

  defp availability_has_rows?(groups) when is_map(groups) do
    Enum.any?(groups, fn {_type, rows} -> rows != [] end)
  end

  defp availability_has_rows?(_), do: false

  defp availability_provider_logo(%{watch_provider: %{logo_path: path}}),
    do: tmdb_url(path, "w92")

  defp availability_provider_logo(_), do: nil

  defp availability_provider_name(%{watch_provider: %{name: name}}), do: name
  defp availability_provider_name(_), do: "Unknown provider"

  defp availability_initials(name) when is_binary(name) do
    name
    |> String.split(~r/\s+/, trim: true)
    |> Enum.take(2)
    |> Enum.map(&String.first/1)
    |> Enum.join()
    |> String.upcase()
  end

  defp availability_initials(_), do: "?"

  defp availability_status_copy(nil, region_label),
    do: "Availability for #{region_label} has not been checked yet."

  defp availability_status_copy(%{status: "no_results"} = freshness, region_label) do
    "No availability found for #{region_label}. " <> freshness_copy(freshness)
  end

  defp availability_status_copy(%{status: "error"} = freshness, region_label) do
    "Availability for #{region_label} could not be refreshed. " <> freshness_copy(freshness)
  end

  defp availability_status_copy(freshness, region_label) do
    "Availability for #{region_label}. " <> freshness_copy(freshness)
  end

  defp freshness_copy(%{fetched_at: fetched_at} = freshness) when not is_nil(fetched_at) do
    copy = "Updated #{relative_days(fetched_at)}."

    if availability_stale?(freshness) do
      copy <> " Availability may have changed."
    else
      copy
    end
  end

  defp freshness_copy(_), do: ""

  defp availability_stale?(%{stale_after: nil}), do: false

  defp availability_stale?(%{stale_after: stale_after}) do
    DateTime.compare(stale_after, DateTime.utc_now()) == :lt
  end

  defp availability_stale?(_), do: false

  defp relative_days(%DateTime{} = fetched_at) do
    days = max(div(DateTime.diff(DateTime.utc_now(), fetched_at, :second), 86_400), 0)

    case days do
      0 -> "today"
      1 -> "1 day ago"
      n -> "#{n} days ago"
    end
  end

  defp tmdb_url(nil, _), do: nil
  defp tmdb_url("", _), do: nil
  defp tmdb_url("/" <> _ = path, size), do: "https://image.tmdb.org/t/p/#{size}#{path}"
  defp tmdb_url(path, size), do: "https://image.tmdb.org/t/p/#{size}/#{path}"
end

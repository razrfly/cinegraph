defmodule CinegraphWeb.MovieLive.IndexV2Components.ActiveChips do
  @moduledoc """
  Active filter chip rendering for the V2 movie index.
  """
  use Phoenix.Component

  alias CinegraphWeb.LiveViewHelpers
  alias CinegraphWeb.MovieLive.IndexV2Components.SortLabels

  @basic_filter_keys ~w(search genres decade lists festivals people_ids rating_preset show_unreleased)

  attr :params, :map, required: true
  attr :filter_options, :map, required: true
  attr :sort_options, :list, required: true

  def active_filters(assigns) do
    chips = build_active_chips(assigns.params, assigns.filter_options, assigns.sort_options)
    assigns = assign(assigns, :chips, chips)

    ~H"""
    <section :if={@chips != []} class="mb-6 flex items-center gap-2 flex-wrap">
      <span class="text-[11px] font-semibold text-mist-500 tracking-[.06em] uppercase">
        ACTIVE
      </span>
      <span
        :for={{key, label, value_label} <- @chips}
        class="inline-flex items-center gap-1.5 rounded-full bg-mist-950/[0.04] border border-mist-950/10 px-[10px] py-[3px] text-[11.5px] text-mist-900"
      >
        <span class="text-mist-500">{label}:</span>
        <span class="font-medium">{value_label}</span>
        <button
          type="button"
          phx-click="remove_filter"
          phx-value-filter={key}
          class="ml-1 inline-flex items-center justify-center w-3.5 h-3.5 text-mist-500 hover:text-mist-950"
          title="Remove"
        >
          ×
        </button>
      </span>
      <button
        type="button"
        phx-click="clear_filters"
        class="ml-2 text-[11.5px] font-medium text-mist-700 underline decoration-mist-950/15 underline-offset-4 hover:text-mist-950"
      >
        Clear all
      </button>
    </section>
    """
  end

  defp build_active_chips(params, filter_options, sort_options) do
    filter_chips =
      @basic_filter_keys
      |> Enum.reject(&(&1 == "search"))
      |> Enum.flat_map(fn key ->
        value = params[key]

        if filter_value_present?(value) do
          [{key, label_for(key), value_label_for(key, value, filter_options)}]
        else
          []
        end
      end)

    sort_chip(params, sort_options) ++ filter_chips
  end

  defp sort_chip(params, sort_options) do
    raw = params["sort"] || ""

    if sort_param_non_default?(raw) do
      criteria = String.replace(raw, ~r/_(asc|desc)$/, "")
      direction = if String.ends_with?(raw, "_asc"), do: :asc, else: :desc

      label =
        case Enum.find(sort_options, &(&1.value == criteria)) do
          nil -> criteria
          opt -> SortLabels.display(opt)
        end

      [{"sort", "Sort", "#{label} #{SortLabels.direction_arrow(direction)}"}]
    else
      []
    end
  end

  defp filter_value_present?(nil), do: false
  defp filter_value_present?(""), do: false
  defp filter_value_present?([]), do: false
  defp filter_value_present?([""]), do: false
  defp filter_value_present?(_), do: true

  defp sort_param_non_default?(raw), do: raw not in [nil, "", "release_date_desc"]

  defp label_for("genres"), do: "Genres"
  defp label_for("decade"), do: "Decade"
  defp label_for("lists"), do: "Lists"
  defp label_for("festivals"), do: "Festivals"
  defp label_for("people_ids"), do: "Cast & Crew"
  defp label_for("rating_preset"), do: "Rating"
  defp label_for("show_unreleased"), do: "Unreleased"
  defp label_for(other), do: other |> String.replace("_", " ") |> String.capitalize()

  defp value_label_for("genres", value, opts) do
    ids = LiveViewHelpers.parse_array_param(value)
    available = opts[:genres] || []

    ids
    |> Enum.map(fn id ->
      id_int = parse_id(id)
      Enum.find(available, &(&1.id == id_int)) || %{name: to_string(id)}
    end)
    |> Enum.map(& &1.name)
    |> truncate_join()
  end

  defp value_label_for("lists", value, opts) do
    keys = LiveViewHelpers.parse_array_param(value)
    available = opts[:lists] || []

    keys
    |> Enum.map(fn k ->
      Enum.find(available, &(&1.key == k)) || %{name: k}
    end)
    |> Enum.map(& &1.name)
    |> truncate_join()
  end

  defp value_label_for("festivals", value, opts) do
    ids = LiveViewHelpers.parse_array_param(value)
    available = opts[:festivals] || []

    ids
    |> Enum.map(fn id ->
      id_int = parse_id(id)
      Enum.find(available, &(&1.id == id_int)) || %{name: to_string(id)}
    end)
    |> Enum.map(& &1.name)
    |> truncate_join()
  end

  defp value_label_for("decade", value, _opts), do: "#{value}s"

  defp value_label_for("rating_preset", value, _opts) do
    case to_string(value) do
      "highly_rated" -> "Highly rated (7.5+)"
      "well_reviewed" -> "Well reviewed (6.0+)"
      "critically_acclaimed" -> "Critically acclaimed"
      other -> other
    end
  end

  defp value_label_for("show_unreleased", "true", _opts), do: "Yes"
  defp value_label_for("show_unreleased", _, _opts), do: "No"

  defp value_label_for("people_ids", value, _opts) do
    ids =
      value
      |> to_string()
      |> String.split(",", trim: true)

    case length(ids) do
      0 -> "—"
      1 -> "1 person"
      n -> "#{n} people"
    end
  end

  defp value_label_for(_, value, _opts) when is_list(value), do: Enum.join(value, ", ")
  defp value_label_for(_, value, _opts), do: to_string(value)

  defp parse_id(id) when is_integer(id), do: id

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp parse_id(_), do: nil

  defp truncate_join(names) do
    joined = Enum.join(names, ", ")
    if String.length(joined) > 30, do: String.slice(joined, 0..27) <> "…", else: joined
  end
end

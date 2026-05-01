defmodule CinegraphWeb.MovieLive.IndexV2.Events do
  @moduledoc """
  V2-specific event handlers for the movie index LiveView.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [push_patch: 2]
  import CinegraphWeb.LiveViewHelpers, only: [parse_array_param: 1]

  def handle_event("toggle_drawer", _params, socket) do
    {:noreply, assign(socket, :show_drawer, !socket.assigns.show_drawer)}
  end

  def handle_event("hide_drawer", _params, socket),
    do: {:noreply, assign(socket, :show_drawer, false)}

  def handle_event("show_scoring_info", _params, socket),
    do: {:noreply, assign(socket, :show_scoring_info, true)}

  def handle_event("hide_scoring_info", _params, socket),
    do: {:noreply, assign(socket, :show_scoring_info, false)}

  def handle_event("toggle_chip", %{"key" => key} = params, socket) do
    mode = params["mode"] || "single"
    value = chip_value(params)
    str_value = to_string(value)

    new_param =
      case mode do
        "multi" ->
          current = parse_array_param(socket.assigns.params[key])

          new_list =
            if str_value in current,
              do: List.delete(current, str_value),
              else: [str_value | current]

          if new_list == [], do: nil, else: new_list

        _ ->
          if to_string(socket.assigns.params[key]) == str_value, do: nil, else: str_value
      end

    new_params =
      socket.assigns.params
      |> put_or_delete(key, new_param)
      |> Map.put("page", "1")

    {:noreply, push_patch(socket, to: socket.view.build_path(socket, new_params))}
  end

  def handle_event("set_rating_preset", %{"value" => value}, socket) do
    set_rating_preset(value, socket)
  end

  def handle_event("set_rating_preset", %{"item" => value}, socket) do
    set_rating_preset(value, socket)
  end

  def handle_event("set_rating_preset", %{"id" => value}, socket) do
    set_rating_preset(value, socket)
  end

  def handle_event("remove_filter", %{"filter" => filter_key} = params, socket) do
    _ = params["filter-type"]

    new_params =
      socket.assigns.params
      |> Map.delete(filter_key)
      |> Map.put("page", "1")

    {:noreply, push_patch(socket, to: socket.view.build_path(socket, new_params))}
  end

  def handle_event(_event, _params, _socket), do: :unknown

  def put_or_delete(map, key, nil), do: Map.delete(map, key)
  def put_or_delete(map, key, ""), do: Map.delete(map, key)
  def put_or_delete(map, key, []), do: Map.delete(map, key)
  def put_or_delete(map, key, value), do: Map.put(map, key, value)

  def set_rating_preset(value, socket) do
    new_value =
      cond do
        value == "" -> nil
        to_string(socket.assigns.params["rating_preset"]) == value -> nil
        true -> value
      end

    new_params =
      socket.assigns.params
      |> put_or_delete("rating_preset", new_value)
      |> Map.put("page", "1")

    {:noreply, push_patch(socket, to: socket.view.build_path(socket, new_params))}
  end

  def chip_value(%{"item" => item}) when item not in [nil, ""], do: item
  def chip_value(%{"id" => id}) when id not in [nil, ""], do: id
  def chip_value(%{"value" => value}), do: value
  def chip_value(_), do: nil
end

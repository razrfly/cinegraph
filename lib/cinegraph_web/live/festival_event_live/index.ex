defmodule CinegraphWeb.FestivalEventLive.Index do
  use CinegraphWeb, :live_view

  alias Cinegraph.Events
  alias Cinegraph.Events.FestivalEvent

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Festival Events")
     |> assign(:festival_events, list_festival_events())
     |> assign(:show_modal, false)
     |> assign(:modal_action, :new)
     |> assign(:festival_event, %FestivalEvent{})}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("new", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_modal, true)
     |> assign(:modal_action, :new)
     |> assign(:festival_event, %FestivalEvent{})}
  end

  @impl true
  def handle_event("edit", %{"id" => id}, socket) do
    festival_event = Events.get_by_source_key(id)
    
    {:noreply,
     socket
     |> assign(:show_modal, true)
     |> assign(:modal_action, :edit)
     |> assign(:festival_event, festival_event)}
  end

  @impl true
  def handle_event("toggle_active", %{"source-key" => source_key}, socket) do
    festival_event = Events.get_by_source_key(source_key)
    
    case Events.update_festival_event(festival_event, %{active: !festival_event.active}) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:festival_events, list_festival_events())
         |> put_flash(:info, "Festival event updated successfully")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to update festival event")}
    end
  end

  @impl true
  def handle_event("close_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_modal, false)
     |> assign(:festival_event, %FestivalEvent{})}
  end

  @impl true
  def handle_event("save", %{"festival_event" => festival_event_params}, socket) do
    save_festival_event(socket, socket.assigns.modal_action, festival_event_params)
  end

  defp save_festival_event(socket, :new, festival_event_params) do
    case Events.create_festival_event(festival_event_params) do
      {:ok, _festival_event} ->
        {:noreply,
         socket
         |> assign(:festival_events, list_festival_events())
         |> assign(:show_modal, false)
         |> put_flash(:info, "Festival event created successfully")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> assign(:changeset, changeset)
         |> put_flash(:error, "Failed to create festival event")}
    end
  end

  defp save_festival_event(socket, :edit, festival_event_params) do
    case Events.update_festival_event(socket.assigns.festival_event, festival_event_params) do
      {:ok, _festival_event} ->
        {:noreply,
         socket
         |> assign(:festival_events, list_festival_events())
         |> assign(:show_modal, false)
         |> put_flash(:info, "Festival event updated successfully")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> assign(:changeset, changeset)
         |> put_flash(:error, "Failed to update festival event")}
    end
  end

  defp list_festival_events do
    Events.list_festival_events()
  end
end
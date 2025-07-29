defmodule CinegraphWeb.PersonLive.Index do
  use CinegraphWeb, :live_view

  alias Cinegraph.People

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :people, list_people())}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "People")
    |> assign(:person, nil)
  end

  defp list_people do
    People.list_people()
  end
end
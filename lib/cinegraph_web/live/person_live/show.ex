defmodule CinegraphWeb.PersonLive.Show do
  use CinegraphWeb, :live_view

  alias Cinegraph.People

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :active_tab, :acting)}
  end

  @impl true
  def handle_params(%{"id" => id}, _url, socket) do
    case People.get_person_with_credits(id) do
      nil ->
        socket = 
          socket
          |> put_flash(:error, "Person not found")
          |> push_navigate(to: ~p"/people")
          
        {:noreply, socket}
        
      person ->
        career_stats = People.get_career_stats(id)
        
        socket = 
          socket
          |> assign(:person, person)
          |> assign(:career_stats, career_stats)
          |> assign(:page_title, person.name)
          
        {:noreply, socket}
    end
  end
  
  @impl true
  def handle_event("change_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, :active_tab, String.to_atom(tab))}
  end
end
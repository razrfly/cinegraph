defmodule CinegraphWeb.PersonLive.Show do
  use CinegraphWeb, :live_view

  alias Cinegraph.People

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket}
  end

  @impl true
  def handle_params(%{"id" => id}, _url, socket) do
    person = People.get_person_with_credits!(id)
    career_stats = People.get_career_stats(id)
    
    socket = 
      socket
      |> assign(:person, person)
      |> assign(:career_stats, career_stats)
      |> assign(:page_title, person.name)
      
    {:noreply, socket}
  end
end
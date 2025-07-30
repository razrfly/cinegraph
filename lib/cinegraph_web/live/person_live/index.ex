defmodule CinegraphWeb.PersonLive.Index do
  use CinegraphWeb, :live_view

  alias Cinegraph.People

  @impl true
  def mount(_params, _session, socket) do
    {:ok, 
     socket
     |> assign(:page, 1)
     |> assign(:per_page, 20)
     |> assign(:people, [])
     |> assign(:total_people, 0)}
  end

  @impl true
  def handle_params(params, _url, socket) do
    page = case Integer.parse(params["page"] || "1") do
      {page_num, _} when page_num > 0 -> page_num
      _ -> 1
    end
    
    per_page = case Integer.parse(params["per_page"] || "20") do
      {per_page_num, _} when per_page_num > 0 and per_page_num <= 100 -> per_page_num
      _ -> 20
    end
    
    people = People.list_people(%{"page" => to_string(page), "per_page" => to_string(per_page)})
    
    # Get total count for pagination
    total_people = People.count_people()
    total_pages = ceil(total_people / per_page)
    
    socket =
      socket
      |> assign(:page, page)
      |> assign(:per_page, per_page)
      |> assign(:people, people)
      |> assign(:total_people, total_people)
      |> assign(:total_pages, total_pages)
      |> assign(:page_title, "People")
      |> assign(:person, nil)
    
    {:noreply, socket}
  end
  
  # Helper function for pagination range
  def pagination_range(current_page, total_pages) when total_pages <= 7 do
    1..total_pages |> Enum.to_list()
  end
  
  def pagination_range(current_page, total_pages) do
    cond do
      current_page <= 3 ->
        [1, 2, 3, 4, "...", total_pages]
        
      current_page >= total_pages - 2 ->
        [1, "...", total_pages - 3, total_pages - 2, total_pages - 1, total_pages]
        
      true ->
        [1, "...", current_page - 1, current_page, current_page + 1, "...", total_pages]
    end
  end
end
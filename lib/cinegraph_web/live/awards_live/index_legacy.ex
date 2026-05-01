defmodule CinegraphWeb.AwardsLive.IndexLegacy do
  @moduledoc """
  LiveView for browsing all festival/awards organizations.
  Provides a clean entry point at /awards showing available festivals.
  """
  use CinegraphWeb, :live_view

  alias Cinegraph.Festivals

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Awards & Festivals")
     |> assign(:organizations, Festivals.list_organizations_with_stats())}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end
end

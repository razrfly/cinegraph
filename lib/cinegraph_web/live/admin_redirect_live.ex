defmodule CinegraphWeb.AdminRedirectLive do
  @moduledoc """
  Tiny LiveView for permanent redirects from old admin routes to their
  new homes (#880 Phase 4).

  Each `live_action` maps to a single target. Mount issues a `push_navigate`
  before any render, so the user lands directly on the new URL.

  Routes registered today:

  - `:festival_events` → `/admin/festivals`
  - `:year_imports` / `:award_imports` → `/admin/imports?tab=...`

  Add a new redirect by registering the route in `router.ex` with the right
  `live_action` and adding a clause to `redirect_target/1` below.
  """
  use CinegraphWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, push_navigate(socket, to: redirect_target(socket.assigns.live_action))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="p-8 text-sm text-gray-500">Redirecting…</div>
    """
  end

  defp redirect_target(:festival_events), do: "/admin/festivals"
  defp redirect_target(:year_imports), do: "/admin/imports?tab=years"
  defp redirect_target(:award_imports), do: "/admin/imports?tab=awards"
  defp redirect_target(_), do: "/admin"
end

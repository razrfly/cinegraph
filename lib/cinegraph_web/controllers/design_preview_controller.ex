defmodule CinegraphWeb.DesignPreviewController do
  use CinegraphWeb, :controller

  alias CinegraphWeb.NeutralDesign.MockData

  @doc """
  Phase 1 smoke test for the Cinegraph Neutral design system.

  Renders the desktop artboard from
  `tmp/cinegraph-design/cinegraph/project/Cinegraph Neutral.html` at a fixed
  1440px width, fed by mock data. Uses `put_root_layout(false)` so the page
  is fully isolated from `app.css` and the main layout — only loads
  `priv/static/assets/cinegraph_neutral.css`.
  """
  def show(conn, _params) do
    conn
    |> put_root_layout(false)
    |> assign_mock_data()
    |> render(:show, layout: false)
  end

  @doc """
  Phase 2.5 — Cinegraph Neutral V2, on Oatmeal foundation.

  Same composition as `show/2`, but uses `NeutralV2Components` with the
  `mist-*` palette + Instrument Serif italic display, loading
  `priv/static/assets/oatmeal.css`.
  """
  def show_v2(conn, _params) do
    conn
    |> put_root_layout(false)
    |> assign_mock_data()
    |> render(:show_v2, layout: false)
  end

  defp assign_mock_data(conn) do
    conn
    |> assign(:films, MockData.films())
    |> assign(:people, MockData.people())
    |> assign(:lists, MockData.lists())
    |> assign(:graph, MockData.graph())
    |> assign(:updates, MockData.updates())
    |> assign(:insights, MockData.insights())
    |> assign(:genres, MockData.genres())
  end
end

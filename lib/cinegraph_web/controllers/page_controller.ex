defmodule CinegraphWeb.PageController do
  use CinegraphWeb, :controller

  def home(conn, _params) do
    # The home page is often custom made,
    # so skip the default app layout.
    render(conn, :home, layout: false)
  end

  def coming_soon(conn, _params) do
    # Temporary landing page while app is in development
    render(conn, :coming_soon, layout: false)
  end
end

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

  def redirect_to_movies(conn, _params) do
    redirect(conn, to: "/movies")
  end

  @doc """
  Marketing manifesto landing page (issue #1020). Self-contained: renders the
  full HTML skeleton loading `oatmeal.css` only, bypassing both the root and app
  layouts. Mirrors the `OatmealDemoController` isolation pattern.
  """
  def manifesto(conn, _params) do
    conn |> put_root_layout(false) |> render(:manifesto, layout: false)
  end
end

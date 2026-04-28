defmodule CinegraphWeb.OatmealDemoController do
  use CinegraphWeb, :controller

  @moduledoc """
  Phase 1 boilerplate verification for the Tailwind Plus Oatmeal kit
  (mist_instrument variant).

  Each action renders a self-contained page that loads
  `priv/static/assets/oatmeal.css` only — fully isolated from `app.css` and
  the main app layout. Mirrors the eventasaurus port pattern. The pages keep
  the upstream Oatmeal "customer support" copy verbatim so the smoke test
  can be compared 1:1 against the upstream Tailwind Plus preview.
  """

  def home(conn, _params) do
    conn |> put_root_layout(false) |> render(:home, layout: false)
  end

  def about(conn, _params) do
    conn |> put_root_layout(false) |> render(:about, layout: false)
  end

  def pricing(conn, _params) do
    conn |> put_root_layout(false) |> render(:pricing, layout: false)
  end

  def error_404(conn, _params) do
    conn |> put_root_layout(false) |> render(:error_404, layout: false)
  end
end

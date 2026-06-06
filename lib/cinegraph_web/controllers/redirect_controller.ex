defmodule CinegraphWeb.RedirectController do
  @moduledoc """
  Permanent redirects for retired routes. `/movies/discover` (the broken v1 tuner, #985) is
  replaced by the tuner embedded in `/algorithms/:slug` (#1038 2c) — old links land on the index.
  """
  use CinegraphWeb, :controller

  def algorithms(conn, _params) do
    conn
    |> put_status(:moved_permanently)
    |> redirect(to: ~p"/algorithms")
  end
end

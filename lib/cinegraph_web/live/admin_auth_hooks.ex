defmodule CinegraphWeb.AdminAuthHooks do
  @moduledoc """
  LiveView `on_mount` hooks for the admin section.

  Currently provides one hook:

  - `:admin_layout` — sets `current_path` on the socket so the admin sidebar
    can highlight the active nav item via `CinegraphWeb.Layouts.admin_nav_active?/3`.

  Authentication is enforced upstream by HTTP Basic Auth in the `:admin`
  router pipeline (`admin_auth/2`); we do not need a socket-level auth hook.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [attach_hook: 4]

  def on_mount(:admin_layout, _params, _session, socket) do
    socket =
      socket
      |> assign(:current_path, nil)
      |> attach_hook(:track_current_path, :handle_params, fn _params, uri, socket ->
        path =
          case URI.parse(uri) do
            %URI{path: path} when is_binary(path) -> path
            _ -> "/"
          end

        {:cont, assign(socket, :current_path, path)}
      end)

    {:cont, socket}
  end
end

defmodule CinegraphWeb.Live.AuthHooksTest do
  use Cinegraph.DataCase, async: true

  alias CinegraphWeb.Live.AuthHooks

  defp socket do
    %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, flash: %{}}}
  end

  describe "on_mount :assign_auth_user" do
    test "assigns current_user from session current_user_id" do
      {:ok, user} = Cinegraph.Accounts.create_user(%{email: "hook@example.com"})

      assert {:cont, socket} =
               AuthHooks.on_mount(
                 :assign_auth_user,
                 %{},
                 %{"current_user_id" => user.id},
                 socket()
               )

      assert socket.assigns.current_user.id == user.id
    end

    test "assigns nil current_user when session has no user" do
      assert {:cont, socket} = AuthHooks.on_mount(:assign_auth_user, %{}, %{}, socket())
      assert socket.assigns.current_user == nil
    end
  end

  describe "on_mount :require_authenticated_user" do
    test "allows the static (disconnected) render to proceed even when anonymous" do
      # During static render connect_params aren't available; we let the page load
      # and re-check on WebSocket connect rather than redirecting.
      assert {:cont, _socket} =
               AuthHooks.on_mount(:require_authenticated_user, %{}, %{}, socket())
    end

    test "continues with an authenticated session user" do
      {:ok, user} = Cinegraph.Accounts.create_user(%{email: "req@example.com"})

      assert {:cont, socket} =
               AuthHooks.on_mount(
                 :require_authenticated_user,
                 %{},
                 %{"current_user_id" => user.id},
                 socket()
               )

      assert socket.assigns.current_user.id == user.id
    end
  end
end

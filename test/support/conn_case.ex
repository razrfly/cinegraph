defmodule CinegraphWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use CinegraphWeb.ConnCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint CinegraphWeb.Endpoint

      use CinegraphWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import CinegraphWeb.ConnCase
    end
  end

  setup tags do
    Cinegraph.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  @doc """
  Creates a user (Clerk-backed accounts, #838) and returns it.
  """
  def user_fixture(attrs \\ %{}) do
    attrs =
      Enum.into(attrs, %{
        email: "user#{System.unique_integer([:positive])}@example.com",
        name: "Test User"
      })

    {:ok, user} = Cinegraph.Accounts.create_user(attrs)
    user
  end

  @doc """
  Setup helper that registers and logs in a user.

  Mirrors the Clerk plug behavior by seeding `current_user_id` in the session.

      setup :register_and_log_in_user
  """
  def register_and_log_in_user(%{conn: conn}) do
    user = user_fixture()
    %{conn: log_in_user(conn, user), user: user}
  end

  @doc """
  Logs the given user into the connection by seeding the session, the same way
  `CinegraphWeb.Plugs.ClerkAuthPlug.sync_clerk_user/2` does.
  """
  def log_in_user(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session("current_user_id", user.id)
    |> Plug.Conn.assign(:current_user, user)
  end
end

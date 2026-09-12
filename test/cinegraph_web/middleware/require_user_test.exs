defmodule CinegraphWeb.Middleware.RequireUserTest do
  use ExUnit.Case, async: true

  alias Cinegraph.ApiCredentials.Principal
  alias CinegraphWeb.Middleware.RequireUser

  test "a service principal does not satisfy the user gate" do
    resolution = %Absinthe.Resolution{
      context: %{
        service_principal: %Principal{
          client_id: 1,
          key_id: 1,
          client_slug: "service",
          scopes: ["catalog:read"],
          kind: :registry
        }
      },
      state: :unresolved
    }

    assert %{errors: ["unauthorized"]} = RequireUser.call(resolution, [])
  end
end

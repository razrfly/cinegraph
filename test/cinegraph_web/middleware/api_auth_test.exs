defmodule CinegraphWeb.Middleware.ApiAuthTest do
  use ExUnit.Case, async: true

  alias Cinegraph.ApiCredentials.Principal
  alias CinegraphWeb.Middleware.ApiAuth

  test "catalog scope is explicit and unknown future scopes fail closed" do
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

    assert %{state: :unresolved} = ApiAuth.call(resolution, "catalog:read")
    assert %{errors: ["unauthorized"]} = ApiAuth.call(resolution, "future:unknown")
  end
end

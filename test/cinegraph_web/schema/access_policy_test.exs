defmodule CinegraphWeb.Schema.AccessPolicyTest do
  use ExUnit.Case, async: true

  alias CinegraphWeb.Middleware.ApiAuth
  alias CinegraphWeb.Schema

  test "undeclared root fields fail closed before their resolver" do
    for root <- [:query, :mutation, :subscription] do
      middleware = Schema.middleware([{:resolver, []}], %{name: "newField"}, %{identifier: root})
      assert [{ApiAuth, :undeclared_policy} | _] = middleware
      resolution = %Absinthe.Resolution{context: %{api_auth_bypass: true}}
      assert %{state: :resolved, errors: [_]} = ApiAuth.call(resolution, :undeclared_policy)
    end
  end

  test "all current catalog root fields have an explicit policy" do
    fields = Schema.__absinthe_type__(:query).fields

    for {_id, field} <- fields, not String.starts_with?(field.name, "__") do
      assert {{ApiAuth, :call}, "catalog:read"} in field.middleware, field.name
      refute {ApiAuth, :undeclared_policy} in field.middleware
    end
  end

  test "introspection and nested fields retain their middleware" do
    assert Schema.middleware([], %{name: "__typename"}, %{identifier: :query}) == []
    assert Schema.middleware([], %{name: "title"}, %{identifier: :movie}) == []
  end
end

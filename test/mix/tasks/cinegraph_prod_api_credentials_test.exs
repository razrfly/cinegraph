defmodule Mix.Tasks.Cinegraph.Prod.ApiCredentialsTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Cinegraph.Prod.ApiCredentials

  test "build_expression transports parameters as JSON without interpolating operator input" do
    expression =
      ApiCredentials.build_expression("key-rotate", %{
        "client" => "client-with-'quotes'",
        "old_public_id" => "cg_old",
        "label" => "quarterly rotation",
        "created_by" => "ops@example.com",
        "expires_at" => nil
      })

    assert expression =~ "Cinegraph.Release.api_credential_command(\"key-rotate\", params)"
    assert expression =~ "Jason.decode!(Base.decode64!"
    refute expression =~ "client-with-'quotes'"
    refute expression =~ "ops@example.com"
  end
end

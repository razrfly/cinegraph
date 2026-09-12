defmodule Cinegraph.ApiCredentials.ReleaseTest do
  use Cinegraph.DataCase, async: false
  import ExUnit.CaptureIO
  alias Cinegraph.{ApiCredentials, Release}

  test "operator workflow issues, overlaps, lists and revokes without leaking list secrets" do
    slug = "release-smoke"

    assert capture_io(fn ->
             Release.api_client_create(%{
               slug: slug,
               label: "Smoke",
               owner_contact: "ops@example.com",
               environment: "test"
             })
           end) =~ "created client"

    output =
      capture_io(fn ->
        Release.api_key_issue(slug, %{
          label: "initial",
          created_by: "ops@example.com",
          expires_at: nil
        })
      end)

    [_, old_token] = Regex.run(~r/CINEGRAPH_API_KEY=(\S+)/, output)
    {:ok, old_id, _} = ApiCredentials.parse_token(old_token)
    assert {:ok, _} = ApiCredentials.authenticate(old_token)

    output =
      capture_io(fn ->
        Release.api_key_rotate(slug, old_id, %{
          label: "rotation",
          created_by: "ops@example.com",
          expires_at: ~U[2027-09-12 00:00:00Z]
        })
      end)

    [_, new_token] = Regex.run(~r/CINEGRAPH_API_KEY=(\S+)/, output)
    assert {:ok, _} = ApiCredentials.authenticate(new_token)
    assert {:ok, _} = ApiCredentials.authenticate(old_token)

    listing =
      capture_io(fn ->
        Release.api_client_list()
        Release.api_key_list(slug)
      end)

    assert listing =~ old_id
    refute listing =~ old_token
    refute listing =~ new_token
    refute listing =~ "secret_digest"

    capture_io(fn -> Release.api_key_revoke(old_id) end)
    assert {:error, :revoked} = ApiCredentials.authenticate(old_token)
    assert {:ok, _} = ApiCredentials.authenticate(new_token)
    capture_io(fn -> Release.api_client_disable(slug) end)
    assert {:error, :disabled} = ApiCredentials.authenticate(new_token)
  end
end

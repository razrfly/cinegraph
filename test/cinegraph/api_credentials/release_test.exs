defmodule Cinegraph.ApiCredentials.ReleaseTest do
  use Cinegraph.DataCase, async: false
  alias Cinegraph.{ApiCredentials, Release}

  test "operator workflow issues, overlaps, lists and revokes without leaking list secrets" do
    slug = "release-smoke"

    assert %{ok: true, client: %{slug: ^slug}} =
             Release.api_client_create(%{
               slug: slug,
               label: "Smoke",
               owner_contact: "ops@example.com",
               environment: "test"
             })

    assert %{ok: true, key: %{public_id: old_id}, token: old_token} =
             Release.api_key_issue(slug, %{
               label: "initial",
               created_by: "ops@example.com",
               expires_at: nil
             })

    {:ok, ^old_id, _} = ApiCredentials.parse_token(old_token)
    assert {:ok, _} = ApiCredentials.authenticate(old_token)

    assert %{
             ok: true,
             token: new_token,
             replaced_public_id: ^old_id,
             old_key_status: "active_until_revoked"
           } =
             Release.api_key_rotate(slug, old_id, %{
               label: "rotation",
               created_by: "ops@example.com",
               expires_at: DateTime.add(DateTime.utc_now(), 3_600)
             })

    assert {:ok, _} = ApiCredentials.authenticate(new_token)
    assert {:ok, _} = ApiCredentials.authenticate(old_token)

    assert %{ok: true, clients: clients} = Release.api_client_list()
    assert %{ok: true, keys: keys} = Release.api_key_list(slug)
    listing = inspect(%{clients: clients, keys: keys})

    assert listing =~ old_id
    refute listing =~ old_token
    refute listing =~ new_token
    refute listing =~ "secret_digest"

    assert %{ok: true, key: %{public_id: ^old_id}} = Release.api_key_revoke(old_id)
    assert {:error, :revoked} = ApiCredentials.authenticate(old_token)
    assert {:ok, _} = ApiCredentials.authenticate(new_token)

    assert %{ok: true, client: %{slug: ^slug, enabled: false}} =
             Release.api_client_disable(slug)

    assert {:error, :disabled} = ApiCredentials.authenticate(new_token)
  end

  test "JSON command dispatcher rejects invalid rotation keys without issuing a token" do
    %{ok: true} =
      Release.api_client_create(%{
        slug: "release-command",
        label: "Command",
        owner_contact: "ops@example.com",
        environment: "test"
      })

    assert %{ok: false, error: "rotation_key_not_found"} =
             Release.api_credential_command("key-rotate", %{
               "client" => "release-command",
               "old_public_id" => "cg_missing",
               "label" => "rotation",
               "created_by" => "ops@example.com",
               "expires_at" => nil
             })

    assert %{ok: true, keys: []} = Release.api_key_list("release-command")
  end
end

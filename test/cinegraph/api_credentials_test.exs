defmodule Cinegraph.ApiCredentialsTest do
  use Cinegraph.DataCase, async: false

  alias Cinegraph.ApiCredentials
  alias Cinegraph.ApiCredentials.{ApiClient, ApiKey}
  alias Cinegraph.Repo

  defmodule FailingRepo do
    def one(_query), do: raise("database unavailable")
  end

  defmodule PolicyRepo do
    def one(_), do: Process.get(:credential_policy_fixture)
  end

  test "every expiry choice also validates scopes" do
    client = client_fixture("scope-policy")
    {:ok, key, token} = key_fixture(client, "policy")

    for expiry <- [nil, DateTime.add(DateTime.utc_now(), 3600)],
        scopes <- [[], ["catalog:write"], ["catalog:read", "unknown"], nil] do
      Process.put(
        :credential_policy_fixture,
        {%{key | expires_at: expiry}, %{client | scopes: scopes}}
      )

      assert {:error, :invalid_scope} = ApiCredentials.authenticate(token, repo: PolicyRepo)
    end

    Process.put(
      :credential_policy_fixture,
      {%{key | expires_at: DateTime.add(DateTime.utc_now(), 3600)}, client}
    )

    assert {:ok, _} = ApiCredentials.authenticate(token, repo: PolicyRepo)
  end

  test "two clients authenticate independently and rotation overlaps until revocation" do
    first = client_fixture("wordhoard-preview")
    second = client_fixture("eventasaurus-production")

    {:ok, old_key, old_token} = key_fixture(first, "old")
    {:ok, new_key, new_token} = key_fixture(first, "rotation")
    {:ok, event_key, event_token} = key_fixture(second, "eventasaurus")

    assert {:ok, %{client_id: first_id, key_id: old_id}} =
             ApiCredentials.authenticate(old_token)

    assert first_id == first.id
    assert old_id == old_key.id
    assert {:ok, %{key_id: new_id}} = ApiCredentials.authenticate(new_token)
    assert new_id == new_key.id
    assert {:ok, %{key_id: event_id}} = ApiCredentials.authenticate(event_token)
    assert event_id == event_key.id

    assert {:ok, _} = ApiCredentials.revoke_key(old_key.public_id)
    assert {:error, :revoked} = ApiCredentials.authenticate(old_token)
    assert {:ok, _} = ApiCredentials.authenticate(new_token)
    assert {:ok, _} = ApiCredentials.authenticate(event_token)

    assert {:ok, _} = ApiCredentials.disable_client(first.slug)
    assert {:error, :disabled} = ApiCredentials.authenticate(new_token)
    assert {:ok, _} = ApiCredentials.authenticate(event_token)
  end

  test "stores only a digest and rejects malformed, public-id-only, and wrong-secret tokens" do
    client = client_fixture("wordhoard-production")
    {:ok, key, token} = key_fixture(client, "initial")
    persisted = Repo.get!(ApiKey, key.id)
    ["cg", public_id, secret] = String.split(token, "_", parts: 3)

    assert byte_size(token) == 79
    assert byte_size(public_id) == 32
    assert byte_size(secret) == 43
    assert byte_size(persisted.secret_digest) == 32
    refute persisted.secret_digest == secret
    refute inspect(persisted) =~ secret

    assert {:error, :malformed} = ApiCredentials.authenticate("cg_#{public_id}")
    assert {:error, :malformed} = ApiCredentials.authenticate(token <> "oversized")

    wrong_secret = String.duplicate("A", 43)
    wrong_token = "cg_#{public_id}_#{wrong_secret}"
    handler_id = "api-credential-error-redaction-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach(
      handler_id,
      [:cinegraph, :api_auth, :stop],
      fn _, _, metadata, _ -> send(test_pid, {:auth_error_metadata, metadata}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert {:error, :wrong_secret} = ApiCredentials.authenticate(wrong_token)
    assert_receive {:auth_error_metadata, metadata}
    refute inspect(metadata) =~ wrong_token
    refute inspect(metadata) =~ wrong_secret
  end

  test "expiration denies at the exact UTC boundary and database failures fail closed" do
    client = client_fixture("boundary-client")
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    {:ok, _key, token} = key_fixture(client, "expires", now)

    assert {:error, :expired} = ApiCredentials.authenticate(token, now: now)

    assert {:error, :registry_unavailable} =
             ApiCredentials.authenticate(token, now: DateTime.add(now, -1), repo: FailingRepo)
  end

  test "issuance requires an explicit expiry choice, including intentional no-expiry" do
    client = client_fixture("explicit-expiry")

    assert {:error, :expiry_choice_required} =
             ApiCredentials.issue_key(client, %{
               label: "missing choice",
               created_by: "operator@example.com"
             })

    assert {:ok, _key, _token} =
             ApiCredentials.issue_key(client, %{
               label: "intentional no expiry",
               created_by: "operator@example.com",
               expires_at: nil
             })
  end

  test "empty and unknown scopes are rejected by changesets and database constraints" do
    base = %{
      slug: "bad-scopes",
      label: "Bad scopes",
      owner_contact: "ops@example.com",
      environment: "test"
    }

    assert {:error, changeset} = ApiCredentials.create_client(Map.put(base, :scopes, []))
    assert "must not be empty" in errors_on(changeset).scopes

    assert {:error, changeset} =
             ApiCredentials.create_client(Map.put(base, :scopes, ["catalog:write"]))

    assert Enum.any?(errors_on(changeset).scopes, &String.contains?(&1, "unknown scopes"))

    assert_raise Ecto.ConstraintError, fn ->
      Repo.transaction(fn ->
        Repo.insert!(%ApiClient{
          slug: "raw-empty-scopes",
          label: "Raw",
          owner_contact: "ops@example.com",
          environment: "test",
          enabled: true,
          scopes: []
        })
      end)
    end
  end

  test "the database restricts deletion of a client with preserved credential rows" do
    client = client_fixture("restricted-delete")
    {:ok, _key, _token} = key_fixture(client, "preserved")

    deletion =
      client
      |> Ecto.Changeset.change()
      |> Ecto.Changeset.no_assoc_constraint(:api_keys)

    assert {:error, changeset} = Repo.delete(deletion)
    assert "are still associated with this entry" in errors_on(changeset).api_keys
  end

  defp client_fixture(slug) do
    {:ok, client} =
      ApiCredentials.create_client(%{
        slug: slug,
        label: slug,
        owner_contact: "ops@example.com",
        environment: "test",
        scopes: ["catalog:read"]
      })

    client
  end

  defp key_fixture(client, label, expires_at \\ nil) do
    ApiCredentials.issue_key(client, %{
      label: label,
      created_by: "operator@example.com",
      expires_at: expires_at
    })
  end
end

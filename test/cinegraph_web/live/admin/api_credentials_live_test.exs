defmodule CinegraphWeb.Admin.ApiCredentialsLiveTest do
  use CinegraphWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias Cinegraph.{ApiCredentials, Repo}
  alias Cinegraph.ApiCredentials.ApiKey

  test "creates a client, issues a key once, rotates and revokes", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/admin/api-credentials")
    assert has_element?(view, "#create-client-form")

    view
    |> form("#create-client-form",
      client: %{
        slug: "web-preview",
        label: "Web preview",
        environment: "preview",
        owner_contact: "owner@example.com"
      }
    )
    |> render_submit()

    assert_patch(view, "/admin/api-credentials?client=web-preview")
    token = issue(view, "first")
    {:ok, id, _} = ApiCredentials.parse_token(token)
    assert {:ok, _} = ApiCredentials.authenticate(token)
    key = Repo.get_by!(ApiKey, public_id: id)
    assert key.created_by == "local-admin"
    refute key.secret_digest == token

    render_submit(view, "issue_key", %{"key" => %{"label" => "duplicate", "expiry" => "never"}})
    assert Repo.aggregate(ApiKey, :count) == 1
    view |> element("#dismiss-api-key") |> render_click()
    refute render(view) =~ token

    next = issue(view, "rotation")
    assert {:ok, _} = ApiCredentials.authenticate(token)
    assert {:ok, _} = ApiCredentials.authenticate(next)
    view |> element("#dismiss-api-key") |> render_click()
    view |> element("#key-#{id} button") |> render_click()
    assert {:error, :revoked} = ApiCredentials.authenticate(token)
    assert {:ok, _} = ApiCredentials.authenticate(next)
    view |> element("#disable-client") |> render_click()
    assert {:error, :disabled} = ApiCredentials.authenticate(next)
    refute has_element?(view, "#issue-key-form")
  end

  test "expired display and fresh mounts never retrieve a plaintext key", %{conn: conn} do
    client = client("display")
    {:ok, view, _} = live(conn, ~p"/admin/api-credentials?client=#{client.slug}")
    token = issue(view, "temporary")
    {:ok, id, _} = ApiCredentials.parse_token(token)
    send(view.pid, {:clear_issued, id})
    refute render(view) =~ token
    refute has_element?(view, "#issued-api-key")
    {:ok, fresh, html} = live(conn, ~p"/admin/api-credentials?client=#{client.slug}")
    refute html =~ token
    refute has_element?(fresh, "#issued-api-key")
  end

  test "requires expiry, records server-side operator and rejects forged key IDs", %{conn: conn} do
    first = client("first")
    other = client("other")

    {:ok, other_key, token} =
      ApiCredentials.issue_key(other, %{label: "other", created_by: "test", expires_at: nil})

    {:ok, view, _} = live(conn, ~p"/admin/api-credentials?client=#{first.slug}")
    render_submit(view, "issue_key", %{"key" => %{"label" => "missing expiry"}})
    assert Repo.aggregate(ApiKey, :count) == 1
    render_click(view, "revoke_key", %{"id" => other_key.public_id})
    assert {:ok, _} = ApiCredentials.authenticate(token)

    render_submit(view, "issue_key", %{
      "key" => %{"label" => "valid", "expiry" => "90", "created_by" => "forged"}
    })

    {:ok, [key]} = ApiCredentials.list_keys(first)
    assert key.created_by == "local-admin"
    assert DateTime.compare(key.expires_at, DateTime.utc_now()) == :gt
  end

  test "HTTP admin authentication is required and a catalog key grants no access", %{conn: conn} do
    previous = Application.get_env(:cinegraph, :admin_auth_disabled)
    old_password = System.get_env("ADMIN_PASSWORD")
    Application.put_env(:cinegraph, :admin_auth_disabled, false)
    System.put_env("ADMIN_PASSWORD", "test-admin-password")

    on_exit(fn ->
      Application.put_env(:cinegraph, :admin_auth_disabled, previous)

      if old_password,
        do: System.put_env("ADMIN_PASSWORD", old_password),
        else: System.delete_env("ADMIN_PASSWORD")
    end)

    assert get(conn, ~p"/admin/api-credentials").status == 401

    {:ok, _, key} =
      ApiCredentials.issue_key(client("service"), %{
        label: "service",
        created_by: "test",
        expires_at: nil
      })

    assert conn
           |> put_req_header("authorization", "Bearer " <> key)
           |> get(~p"/admin/api-credentials")
           |> Map.fetch!(:status) == 401
  end

  test "invalid key labels show validation errors without issuing a key", %{conn: conn} do
    client = client("validation")
    {:ok, view, _} = live(conn, ~p"/admin/api-credentials?client=#{client.slug}")
    html = render_submit(view, "issue_key", %{"key" => %{"label" => " ", "expiry" => "90"}})
    assert html =~ "can&#39;t be blank"
    assert Repo.aggregate(ApiKey, :count) == 0
    refute has_element?(view, "#issued-api-key")
  end

  defp issue(view, label) do
    view |> form("#issue-key-form", key: %{label: label, expiry: "never"}) |> render_submit()

    view
    |> element("#issued-api-key")
    |> render()
    |> Floki.parse_fragment!()
    |> Floki.attribute("value")
    |> hd()
  end

  defp client(slug) do
    {:ok, client} =
      ApiCredentials.create_client(%{
        slug: slug,
        label: slug,
        environment: "preview",
        owner_contact: "test@example.com"
      })

    client
  end
end

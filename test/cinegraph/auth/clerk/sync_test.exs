defmodule Cinegraph.Auth.Clerk.SyncTest do
  use Cinegraph.DataCase, async: true

  alias Cinegraph.Accounts
  alias Cinegraph.Auth.Clerk.Sync

  describe "sync_user/2 — find-or-create" do
    test "finds an existing user by integer userId claim (PK)" do
      {:ok, user} = Accounts.create_user(%{email: "byid@example.com", name: "By Id"})

      claims = %{
        "sub" => "user_abc",
        "userId" => Integer.to_string(user.id),
        "email" => "byid@example.com"
      }

      assert {:ok, found} = Sync.sync_user(claims)
      assert found.id == user.id
    end

    test "falls back to email lookup when no userId claim" do
      {:ok, user} = Accounts.create_user(%{email: "byemail@example.com"})

      claims = %{"sub" => "user_abc", "email" => "byemail@example.com"}

      assert {:ok, found} = Sync.sync_user(claims)
      assert found.id == user.id
    end

    test "creates a new local user from claims (no network in test)" do
      claims = %{
        "sub" => "user_new",
        "email" => "fresh@example.com",
        "first_name" => "Fresh",
        "last_name" => "User",
        "image_url" => "http://img/avatar.png"
      }

      assert {:ok, user} = Sync.sync_user(claims)
      assert user.email == "fresh@example.com"
      assert user.name == "Fresh User"
      assert user.avatar_url == "http://img/avatar.png"
      assert Accounts.get_user_by_email("fresh@example.com")
    end

    test "derives a name from the email when no name claims are present" do
      claims = %{"sub" => "user_n", "email" => "namefromhere@example.com"}
      assert {:ok, user} = Sync.sync_user(claims)
      assert user.name == "namefromhere"
    end

    test "rejects non-map claims" do
      assert {:error, :invalid_claims} = Sync.sync_user("nope")
    end
  end

  describe "get_user/1 — read-only" do
    test "returns {:error, :not_found} when nothing matches" do
      assert {:error, :not_found} = Sync.get_user(%{"email" => "missing@example.com"})
    end

    test "finds by email without creating" do
      {:ok, user} = Accounts.create_user(%{email: "ro@example.com"})
      assert {:ok, found} = Sync.get_user(%{"email" => "ro@example.com"})
      assert found.id == user.id
    end
  end
end

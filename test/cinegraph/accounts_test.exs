defmodule Cinegraph.AccountsTest do
  use Cinegraph.DataCase, async: true

  alias Cinegraph.Accounts
  alias Cinegraph.Accounts.User

  describe "create_user/1" do
    test "creates a user with valid attrs and downcases email" do
      assert {:ok, %User{} = user} =
               Accounts.create_user(%{email: "Jane@Example.COM", name: "Jane"})

      assert user.email == "jane@example.com"
      assert user.name == "Jane"
      assert user.metadata == %{}
    end

    test "requires an email" do
      assert {:error, changeset} = Accounts.create_user(%{name: "No Email"})
      assert %{email: ["can't be blank"]} = errors_on(changeset)
    end

    test "rejects malformed emails" do
      assert {:error, changeset} = Accounts.create_user(%{email: "not-an-email"})
      assert %{email: [_]} = errors_on(changeset)
    end

    test "rejects an email with a trailing newline (\\A/\\z anchors)" do
      assert {:error, changeset} = Accounts.create_user(%{email: "a@b.com\n"})
      assert %{email: [_]} = errors_on(changeset)
    end

    test "enforces case-insensitive email uniqueness" do
      assert {:ok, _} = Accounts.create_user(%{email: "dup@example.com"})
      assert {:error, changeset} = Accounts.create_user(%{email: "DUP@example.com"})
      assert %{email: ["has already been taken"]} = errors_on(changeset)
    end
  end

  describe "lookups" do
    test "get_user/1 by id and nil-safety" do
      {:ok, user} = Accounts.create_user(%{email: "find@example.com"})
      assert Accounts.get_user(user.id).id == user.id
      assert Accounts.get_user(-1) == nil
      assert Accounts.get_user("not-an-int") == nil
    end

    test "get_user_by_email/1 is case-insensitive" do
      {:ok, user} = Accounts.create_user(%{email: "mixed@example.com"})
      assert Accounts.get_user_by_email("MIXED@example.com").id == user.id
      assert Accounts.get_user_by_email(nil) == nil
    end
  end

  describe "update_user/2" do
    test "updates mutable fields" do
      {:ok, user} = Accounts.create_user(%{email: "u@example.com"})

      assert {:ok, updated} =
               Accounts.update_user(user, %{name: "New", avatar_url: "http://x/y.png"})

      assert updated.name == "New"
      assert updated.avatar_url == "http://x/y.png"
    end
  end
end

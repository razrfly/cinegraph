defmodule Cinegraph.ProdRpcTest do
  # Pure tests — no actual ssh. Cover the parts of ProdRpc that don't
  # require a remote host (env handling, command construction, JSON
  # parsing branches).
  use ExUnit.Case, async: false

  alias Cinegraph.ProdRpc

  describe "app_bin/0" do
    test "returns {:error, :app_bin_not_set} when env var unset" do
      original = System.get_env("REMOTE_APP_BIN")
      System.delete_env("REMOTE_APP_BIN")

      try do
        assert ProdRpc.app_bin() == {:error, :app_bin_not_set}
      after
        case original do
          nil -> System.delete_env("REMOTE_APP_BIN")
          val -> System.put_env("REMOTE_APP_BIN", val)
        end
      end
    end

    test "returns {:error, :app_bin_not_set} when env var empty" do
      System.put_env("REMOTE_APP_BIN", "")
      assert ProdRpc.app_bin() == {:error, :app_bin_not_set}
    after
      System.delete_env("REMOTE_APP_BIN")
    end

    test "returns {:ok, path} when env var set" do
      System.put_env("REMOTE_APP_BIN", "/some/path/cinegraph")
      assert ProdRpc.app_bin() == {:ok, "/some/path/cinegraph"}
    after
      System.delete_env("REMOTE_APP_BIN")
    end
  end

  describe "build_args/2" do
    test "constructs ssh command with options, host, and quoted remote command" do
      System.put_env("REMOTE_SSH_HOST", "test.example")
      assert {:ok, args} = ProdRpc.build_args("/path/cinegraph", ~s|IO.puts("hi")|)
      assert "test.example" in args
      assert Enum.any?(args, &String.contains?(&1, "/path/cinegraph eval"))
      # Should include the expression, with double-quotes escaped
      remote_cmd = Enum.find(args, &String.contains?(&1, "/path/cinegraph"))
      assert String.contains?(remote_cmd, "IO.puts(")
      assert String.contains?(remote_cmd, "\\\"hi\\\"")
    after
      System.delete_env("REMOTE_SSH_HOST")
    end

    test "escapes shell metacharacters in expression" do
      assert {:ok, args} = ProdRpc.build_args("/bin/cinegraph", ~s|IO.puts("$HOME `id`")|)
      remote_cmd = List.last(args)
      # `$` and backticks must be escaped so the remote shell doesn't expand them
      assert String.contains?(remote_cmd, "\\$HOME")
      assert String.contains?(remote_cmd, "\\`id\\`")
    end
  end

  describe "decode_json/1" do
    test "decodes valid JSON object" do
      assert ProdRpc.decode_json(~s|{"status":"ok"}|) == {:ok, %{"status" => "ok"}}
    end

    test "trims whitespace and trailing newlines" do
      assert ProdRpc.decode_json("  {\"a\":1}\n\n") == {:ok, %{"a" => 1}}
    end

    test "returns {:error, {:json_parse_failed, raw, _}} for non-JSON" do
      assert {:error, {:json_parse_failed, "boom", %Jason.DecodeError{}}} =
               ProdRpc.decode_json("boom")
    end
  end
end

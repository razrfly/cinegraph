defmodule Cinegraph.ProdRpcTest do
  # Pure tests — don't actually call kamal. Cover the parts of ProdRpc that
  # don't require shelling out (command construction, JSON parsing branches).
  use ExUnit.Case, async: false

  alias Cinegraph.ProdRpc

  describe "locate_kamal/0" do
    test "returns {:ok, path} when kamal is on PATH" do
      # In dev/CI, kamal is installed via mise. If it's missing on a fresh
      # machine, this test is the early-warning signal.
      case ProdRpc.locate_kamal() do
        {:ok, path} ->
          assert is_binary(path)
          assert String.ends_with?(path, "kamal")

        {:error, :kamal_not_found} ->
          flunk("kamal CLI not on PATH — install via mise or kamal-deploy.org")
      end
    end
  end

  describe "build_kamal_args/1" do
    test "constructs `app exec --reuse --quiet --primary --env PHX_SERVER=false` invocation" do
      args = ProdRpc.build_kamal_args(~s|IO.puts("hi")|)

      assert "app" in args and "exec" in args
      assert "--reuse" in args
      assert "--quiet" in args
      assert "--primary" in args
      shell_cmd = List.last(args)
      assert String.starts_with?(shell_cmd, ~s|sh -c "unset PHX_SERVER; bin/cinegraph eval |)
      assert String.contains?(shell_cmd, ~s|IO.puts("hi")|)
    end

    test "wraps expression with Application.ensure_all_started/1" do
      args = ProdRpc.build_kamal_args(~s|IO.puts("hi")|)
      shell_cmd = List.last(args)
      assert String.contains?(shell_cmd, "Application.ensure_all_started(:cinegraph)")
    end

    test "single-quotes the wrapped expression for the container shell" do
      args = ProdRpc.build_kamal_args(~s|IO.puts("hi")|)
      shell_cmd = List.last(args)
      # Inside the outer double-quoted sh -c, the bin/cinegraph eval arg is
      # single-quoted so the eval expression survives intact.
      assert String.contains?(shell_cmd, ~s|'Application.ensure_all_started(:cinegraph); IO.puts("hi")'|)
    end

    test "escapes embedded single quotes (POSIX-safe)" do
      args = ProdRpc.build_kamal_args(~s|a'b|)
      shell_cmd = List.last(args)
      assert String.contains?(shell_cmd, ~s|a'\\''b|)
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

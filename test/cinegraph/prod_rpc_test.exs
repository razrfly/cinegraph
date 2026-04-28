defmodule Cinegraph.ProdRpcTest do
  # Pure tests — don't actually call kamal. Cover the parts of ProdRpc that
  # don't require shelling out (command construction, JSON parsing branches).
  use ExUnit.Case, async: false

  alias Cinegraph.ProdRpc

  describe "locate_kamal/0" do
    @tag :kamal
    test "returns {:ok, path} when kamal is on PATH" do
      # Tagged :kamal so CI / fresh machines without the CLI can exclude it
      # (`mix test --exclude kamal`). When kamal *is* installed (dev via
      # mise), this asserts the locator returns a sane path.
      if System.find_executable("kamal") do
        assert {:ok, path} = ProdRpc.locate_kamal()
        assert is_binary(path)
        assert String.ends_with?(path, "kamal")
      else
        assert ProdRpc.locate_kamal() == {:error, :kamal_not_found}
      end
    end
  end

  describe "build_kamal_args/1" do
    test "constructs `app exec --reuse --quiet --primary` invocation with unset PHX_SERVER" do
      # Use a double-quote-free expression here so we can assert on the
      # plain wrapped form. The escape-for-outer-shell behavior is covered
      # in the dedicated test below.
      args = ProdRpc.build_kamal_args(~s|:ok|)

      assert "app" in args and "exec" in args
      assert "--reuse" in args
      assert "--quiet" in args
      assert "--primary" in args
      shell_cmd = List.last(args)
      assert String.starts_with?(shell_cmd, ~s|sh -c "unset PHX_SERVER; bin/cinegraph eval |)
      assert String.ends_with?(shell_cmd, ~s|"|)
    end

    test "wraps expression with Application.ensure_all_started/1" do
      args = ProdRpc.build_kamal_args(~s|:ok|)
      shell_cmd = List.last(args)
      assert String.contains?(shell_cmd, "Application.ensure_all_started(:cinegraph)")
    end

    test "single-quotes the wrapped expression for the container shell" do
      args = ProdRpc.build_kamal_args(~s|:ok|)
      shell_cmd = List.last(args)
      # Inside the outer double-quoted sh -c, the bin/cinegraph eval arg is
      # single-quoted so the eval expression survives intact. The full
      # wrapped form prepends a logger-silence call and ensure_all_started
      # before the user expression.
      assert String.contains?(
               shell_cmd,
               ~s|':logger.set_primary_config(:level, :critical); Application.ensure_all_started(:cinegraph); :ok'|
             )
    end

    test "escapes embedded single quotes (POSIX-safe)" do
      # Input `a'b` becomes `a'\''b` (POSIX), which is then escaped for the
      # outer double-quoted layer: `\` → `\\`. Net substring: `a'\\''b`.
      args = ProdRpc.build_kamal_args(~s|a'b|)
      shell_cmd = List.last(args)
      assert String.contains?(shell_cmd, ~s|a'\\\\''b|)
    end

    test "escapes embedded double quotes for the outer remote shell" do
      # `IO.puts("hi")` would otherwise terminate the outer `sh -c "..."`
      # at the first inner `"`, so the container shell would see the
      # malformed expression `IO.puts(hi)` and fail. The escape ensures the
      # `"` survives as a literal char inside the inner single-quoted arg.
      args = ProdRpc.build_kamal_args(~s|IO.puts("hi")|)
      shell_cmd = List.last(args)
      assert String.contains?(shell_cmd, ~S|IO.puts(\"hi\")|)
      refute String.contains?(shell_cmd, ~s|IO.puts("hi")|)
    end

    test "escapes outer-shell metacharacters ($ and backtick)" do
      # `$x` and `` `cmd` `` would trigger variable / command substitution
      # in the outer double-quoted region; both must be escaped so the
      # container shell sees them as literal text inside the inner quotes.
      args = ProdRpc.build_kamal_args(~s|"$x" <> "`cmd`"|)
      shell_cmd = List.last(args)
      assert String.contains?(shell_cmd, ~S|\$x|)
      assert String.contains?(shell_cmd, ~S|\`cmd\`|)
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

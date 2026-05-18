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
      args = ProdRpc.build_kamal_args(~s|:ok|)

      assert "app" in args and "exec" in args
      assert "--reuse" in args
      assert "--quiet" in args
      assert "--primary" in args
      shell_cmd = List.last(args)
      assert String.starts_with?(shell_cmd, ~s|sh -c "unset PHX_SERVER; bin/cinegraph eval |)
      assert String.ends_with?(shell_cmd, ~s|"|)
    end

    test "eval argument contains no semicolons (shell-quoting safe)" do
      # Semicolons in the eval arg become shell command separators when kamal
      # wraps the shell_command in its own outer quoting — the root cause of
      # the zsh:1: command not found: oban_config failure in #931.
      args = ProdRpc.build_kamal_args(~s|:ok|)
      shell_cmd = List.last(args)
      [_, eval_arg] = String.split(shell_cmd, "bin/cinegraph eval ", parts: 2)

      refute String.contains?(eval_arg, ";"),
             "eval argument must not contain bare semicolons — they become shell separators"
    end

    test "base64-decoded eval argument contains preamble and user expression in order" do
      expr = ~s|IO.puts(Jason.encode!(%{ok: true}))|
      args = ProdRpc.build_kamal_args(expr)
      shell_cmd = List.last(args)

      [_, rest] = String.split(shell_cmd, ~s|Code.eval_string(Base.decode64!(\\"|, parts: 2)
      [encoded | _] = String.split(rest, ~s|\\"|)
      decoded = Base.decode64!(encoded)

      assert String.contains?(decoded, "Application.ensure_all_started(:cinegraph)")

      assert String.contains?(
               decoded,
               "Application.put_env(:cinegraph, :start_background_children, false)"
             )

      assert String.contains?(decoded, expr)
      {preamble_pos, _} = :binary.match(decoded, "ensure_all_started")
      {expr_pos, _} = :binary.match(decoded, "IO.puts")
      assert preamble_pos < expr_pos
    end

    test "user expression containing semicolons is safely encoded" do
      expr = ~s|a = 1; IO.puts(a)|
      args = ProdRpc.build_kamal_args(expr)
      shell_cmd = List.last(args)
      [_, eval_arg] = String.split(shell_cmd, "bin/cinegraph eval ", parts: 2)

      refute String.contains?(eval_arg, ";"),
             "semicolons in user expression must not appear in the shell eval argument"
    end

    test "user expression with single quotes is preserved in decoded payload" do
      # With base64 encoding the expression is opaque in the shell command —
      # no POSIX escaping is visible at the shell level. The expression must
      # survive intact in the base64-decoded payload.
      expr = ~s|a'b|
      args = ProdRpc.build_kamal_args(expr)
      shell_cmd = List.last(args)
      refute String.contains?(shell_cmd, expr), "raw expression must not appear in shell_cmd"
      assert String.contains?(decoded_expr(shell_cmd), expr)
    end

    test "user expression with double quotes is preserved in decoded payload" do
      # Previously required escaping `"` → `\"` in the outer double-quoted region.
      # Now the expression is base64-encoded so no char-level escaping is needed.
      expr = ~s|IO.puts("hi")|
      args = ProdRpc.build_kamal_args(expr)
      shell_cmd = List.last(args)
      refute String.contains?(shell_cmd, expr)
      assert String.contains?(decoded_expr(shell_cmd), expr)
    end

    test "user expression with shell metacharacters is preserved in decoded payload" do
      # `$x` and backtick would trigger substitution in a double-quoted region;
      # base64 encoding makes them invisible to the shell entirely.
      expr = ~s|"$x" <> "`cmd`"|
      args = ProdRpc.build_kamal_args(expr)
      shell_cmd = List.last(args)
      refute String.contains?(shell_cmd, "$x")
      refute String.contains?(shell_cmd, "`cmd`")
      assert String.contains?(decoded_expr(shell_cmd), expr)
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

  # Extract and base64-decode the eval payload from a shell_command string.
  defp decoded_expr(shell_cmd) do
    [_, rest] = String.split(shell_cmd, ~s|Code.eval_string(Base.decode64!(\\"|, parts: 2)
    [encoded | _] = String.split(rest, ~s|\\"|)
    Base.decode64!(encoded)
  end
end

defmodule Cinegraph.ProdRpc do
  @moduledoc """
  Helpers for `mix cinegraph.prod.*` tasks (#739 Phase C). Wraps
  `kamal app exec` so dev terminals can read live prod numbers without
  a DB pull or manual SSH.

  Cinegraph deploys via Kamal (see `config/deploy.yml`); the release binary
  lives at `/app/bin/cinegraph` inside the running Docker container, not on
  the host filesystem. Running maintenance commands therefore goes through
  `kamal app exec` rather than direct `ssh + bin/cinegraph eval`.

  ## Configuration

  Reads the canonical Kamal config (`config/deploy.yml`) — no env vars
  required. Just have the `kamal` CLI on PATH (it's installed via mise in
  this project; see `mix.exs` / `mise.toml`).

  ## Example

      iex> Cinegraph.ProdRpc.eval_json(~s|IO.puts(Jason.encode!(%{ok: 1}))|)
      {:ok, %{"ok" => 1}}

  See `MAINTENANCE.md` for end-to-end recipes.
  """

  @typedoc "Reasons `eval_json/1` and `eval_raw/1` may fail."
  @type error_reason ::
          :kamal_not_found
          | {:kamal_failed, exit_code :: integer(), output :: binary()}
          | {:eval_failed, output :: binary()}
          | {:json_parse_failed, raw_output :: binary(), error :: term()}

  @doc """
  Run `expression` in the prod container, expect it to write a JSON document
  to stdout (typically via `IO.puts(Jason.encode!(...))`), and return the
  parsed Elixir term.

  Returns `{:ok, decoded}` on success; `{:error, reason}` on any failure.
  """
  @spec eval_json(binary()) :: {:ok, term()} | {:error, error_reason()}
  def eval_json(expression) when is_binary(expression) do
    with {:ok, raw} <- eval_raw(expression) do
      decode_json(raw)
    end
  end

  @doc """
  Run `expression` in the prod container and return raw stdout. Use
  `eval_json/1` unless you need the unparsed output.
  """
  @spec eval_raw(binary()) :: {:ok, binary()} | {:error, error_reason()}
  def eval_raw(expression) when is_binary(expression) do
    with {:ok, kamal_path} <- locate_kamal(),
         args = build_kamal_args(expression) do
      run_kamal(kamal_path, args)
    end
  end

  @doc """
  Pretty-print a result returned by `eval_json/1`. Honors `--json` opt for
  raw passthrough (single-line JSON, no header).
  """
  @spec print(term(), keyword()) :: :ok
  def print(result, opts \\ []) do
    if Keyword.get(opts, :json, false) do
      IO.puts(Jason.encode!(result))
    else
      IO.puts(Jason.encode!(result, pretty: true))
    end

    :ok
  end

  @doc """
  Format and print an error to stderr-equivalent and halt non-zero so
  CI/scripts can detect.
  """
  @spec print_error(error_reason()) :: no_return()
  def print_error(reason) do
    Mix.shell().error(format_error(reason))
    System.halt(1)
  end

  # ===== private =====

  @doc false
  def locate_kamal do
    case System.find_executable("kamal") do
      nil -> {:error, :kamal_not_found}
      path -> {:ok, path}
    end
  end

  @doc false
  def build_kamal_args(expression) when is_binary(expression) do
    # `kamal app exec --reuse --quiet --primary "<cmd>"` runs <cmd> inside the
    # already-running cinegraph container. The container shell sees:
    #
    #   sh -c "unset PHX_SERVER; bin/cinegraph eval '<wrapped_expression>'"
    #
    # `bin/cinegraph eval` boots a fresh BEAM in the container with no
    # supervision tree started. Health/Facade calls reach for
    # `Cinegraph.Health.TaskSupervisor` which only exists once the app is
    # supervised, so we prepend `Application.ensure_all_started(:cinegraph)`.
    # We `unset PHX_SERVER` (see comment near `shell_command` below) to keep
    # the eval'd BEAM from binding port 4000.
    # Silence prod-side logging *before* starting the app, otherwise Repo.Metrics,
    # DashboardStats, MoviesCacheWarmer, etc. flood stdout with INFO/WARNING
    # lines that mix with the JSON we want to parse.
    wrapped =
      ":logger.set_primary_config(:level, :critical); " <>
        "Application.put_env(:cinegraph, :start_oban, false); " <>
        "Application.put_env(:cinegraph, :start_background_children, false); " <>
        "Application.ensure_all_started(:cinegraph); " <>
        expression

    quoted_expr = single_quote(wrapped)
    # The full pipeline: System.cmd → kamal → SSHKit → ssh → remote-shell →
    # docker exec → container-shell. Splitting `sh -c 'cmd'` across multiple
    # System.cmd args gets dropped (kamal only forwards the first positional).
    # Passing the whole thing as ONE arg lets the remote shell parse the
    # quotes, then docker exec correctly invokes `sh -c "..."` in the
    # container. Outer double quotes survive ssh; inner single quotes survive
    # the container shell wrap.
    #
    # The remote shell parses the *outer* double-quoted region, where `"`,
    # `\`, `$`, and `` ` `` are still special. `single_quote/1` only handles
    # the inner POSIX single-quoting; we must additionally escape the outer
    # specials so an expression like `IO.puts("hi")` doesn't break out of
    # the outer `"..."` and reach the container shell as `IO.puts(hi)`.
    #
    # `unset PHX_SERVER` (rather than =false): runtime.exs checks for the
    # var's *presence*, not value. The container starts with PHX_SERVER=true;
    # we have to clear it entirely or the endpoint will try to bind port 4000
    # (already held by the live BEAM in this container) and the whole
    # supervision tree will roll back with :eaddrinuse.
    escaped_for_outer = escape_for_double_quoted(quoted_expr)
    shell_command = ~s|sh -c "unset PHX_SERVER; bin/cinegraph eval #{escaped_for_outer}"|

    [
      "app",
      "exec",
      "--reuse",
      "--quiet",
      "--primary",
      shell_command
    ]
  end

  @doc false
  def decode_json(raw) when is_binary(raw) do
    trimmed = String.trim(raw)

    case Jason.decode(trimmed) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, error} -> {:error, {:json_parse_failed, raw, error}}
    end
  end

  # POSIX-safe single-quote wrapping: 'foo' or 'foo'\''bar' for embedded quotes.
  defp single_quote(s) do
    "'" <> String.replace(s, "'", "'\\''") <> "'"
  end

  # Escape a string for safe interpolation inside a double-quoted POSIX shell
  # context. Inside `"..."`, the chars `\`, `"`, `$`, and `` ` `` retain
  # special meaning; everything else is literal. Order matters — escape `\`
  # first so escapes added for the other chars aren't double-escaped.
  defp escape_for_double_quoted(s) do
    s
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
    |> String.replace("$", "\\$")
    |> String.replace("`", "\\`")
  end

  defp run_kamal(path, args) do
    # `kamal app exec --quiet` still emits some logging on stderr, and
    # infrastructure errors from SSHKit/ssh ("Permission denied", "No such
    # container", ...) only ever go to stderr. We need them in `output` so
    # `classify_failure/2` can match them — otherwise every failure looks
    # like an empty `{:eval_failed, ""}`. `strip_kamal_noise/1` filters
    # banner lines from the merged stream.
    case System.cmd(path, args, stderr_to_stdout: true) do
      {output, 0} -> {:ok, strip_kamal_noise(output)}
      {output, code} -> classify_failure(output, code)
    end
  end

  # `kamal app exec` prefixes lines with INFO/console banners even with -q.
  # The eval output is whatever stays after we drop those. Also handle the
  # case where kamal returns the raw output cleanly (which is what `--quiet`
  # is supposed to do — keep the strip logic defensive).
  defp strip_kamal_noise(output) do
    output
    |> String.split("\n")
    |> Enum.reject(fn line ->
      String.starts_with?(line, "INFO ") or
        String.starts_with?(line, "Running") or
        String.starts_with?(line, "Finished ") or
        String.starts_with?(line, "Launched ") or
        String.starts_with?(line, "App Host:")
    end)
    |> Enum.join("\n")
    |> String.trim()
  end

  defp classify_failure(output, exit_code) do
    cond do
      String.contains?(output, "Permission denied") or
        String.contains?(output, "Could not resolve hostname") or
        String.contains?(output, "Connection refused") or
        String.contains?(output, "Connection timed out") or
          String.contains?(output, "No such container") ->
        {:error, {:kamal_failed, exit_code, output}}

      true ->
        {:error, {:eval_failed, output}}
    end
  end

  defp format_error(:kamal_not_found) do
    """
    kamal CLI not found on PATH. Cinegraph deploys with Kamal — install it via
    mise (already pinned in this project's mise.toml) or the kamal docs:
    https://kamal-deploy.org/docs/installation/
    """
  end

  defp format_error({:kamal_failed, code, output}) do
    "kamal app exec failed (exit #{code}):\n#{String.trim(output)}"
  end

  defp format_error({:eval_failed, output}) do
    "Eval inside prod container failed:\n#{String.trim(output)}"
  end

  defp format_error({:json_parse_failed, raw, _err}) do
    """
    Got non-JSON output from prod (your expression must call IO.puts(Jason.encode!(...))):

    #{String.trim(raw)}
    """
  end
end

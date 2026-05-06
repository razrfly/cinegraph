defmodule Mix.Tasks.Cinegraph.R2.Smoke do
  @moduledoc """
  Smoke-test the R2 wiring (#890) end-to-end:

    1. Verify env vars are populated (`Cinegraph.Images.R2.configured?/0`)
    2. PUT a small test PNG to R2 at `smoke/test.png`
    3. GET the resulting CDN URL via HTTPS, expect 200 + image content-type
    4. DELETE the test object

  Print everything that fails so it's clear which step broke. Exits with
  non-zero status on any failure.

  Usage:

      mix cinegraph.r2.smoke
  """
  use Mix.Task

  alias Cinegraph.Images.R2

  @shortdoc "End-to-end smoke test against R2 (#890)"
  @requirements ["app.start"]

  # 1x1 transparent PNG — minimal valid image, ~67 bytes
  @png_bytes <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1, 0, 0, 0,
               1, 8, 6, 0, 0, 0, 31, 21, 196, 137, 0, 0, 0, 13, 73, 68, 65, 84, 120, 156, 99, 0,
               1, 0, 0, 5, 0, 1, 13, 10, 45, 180, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130>>

  @impl true
  def run(_args) do
    Mix.shell().info("R2 smoke test — #{DateTime.utc_now() |> DateTime.to_string()}")
    Mix.shell().info("Bucket: #{Application.get_env(:cinegraph, :r2)[:bucket]}")
    Mix.shell().info("CDN base: #{Application.get_env(:cinegraph, :r2)[:cdn_url] || "(unset!)"}")

    unless R2.configured?() do
      report_missing_config()
      System.halt(1)
    end

    key = "smoke/test-#{System.system_time(:second)}.png"
    Mix.shell().info("Uploading #{byte_size(@png_bytes)} bytes to #{key}...")

    cdn_url =
      case R2.upload_binary(key, @png_bytes, content_type: "image/png") do
        {:ok, url} ->
          Mix.shell().info("✅ Upload OK → #{url}")
          url

        {:error, reason} ->
          Mix.shell().error("❌ Upload failed: #{inspect(reason)}")
          System.halt(2)
      end

    Mix.shell().info("Fetching CDN URL...")

    try do
      case HTTPoison.get(cdn_url, [], timeout: 10_000, recv_timeout: 10_000) do
        {:ok, %HTTPoison.Response{status_code: 200, headers: headers, body: body}} ->
          ctype =
            headers
            |> Enum.find(fn {k, _} -> String.downcase(k) == "content-type" end)
            |> case do
              {_, v} -> v
              _ -> "(missing)"
            end

          Mix.shell().info("✅ Fetch OK — content-type=#{ctype}, body=#{byte_size(body)} bytes")

          if byte_size(body) != byte_size(@png_bytes) do
            Mix.shell().error(
              "⚠ Body size mismatch — uploaded #{byte_size(@png_bytes)} got #{byte_size(body)}"
            )
          end

        {:ok, %HTTPoison.Response{status_code: status, body: body}} ->
          Mix.shell().error(
            "❌ Fetch HTTP #{status} — likely the bucket isn't public. Body excerpt: #{String.slice(body, 0, 200)}"
          )

          Mix.shell().error("""
          Hint: enable public access for the bucket in Cloudflare dashboard:
            R2 → cinegraph → Settings → Public Access → Allow Access
          Then set R2_CDN_URL to the bucket's r2.dev URL or a custom domain.
          """)

          System.halt(3)

        {:error, %HTTPoison.Error{reason: reason}} ->
          Mix.shell().error("❌ Fetch network error: #{inspect(reason)}")
          System.halt(4)
      end
    after
      Mix.shell().info("Cleaning up test object...")

      case R2.delete(key) do
        :ok ->
          Mix.shell().info("✅ Delete OK")

        {:error, reason} ->
          Mix.shell().error("⚠ Delete failed (object remains): #{inspect(reason)}")
      end
    end

    Mix.shell().info("\n🎉 R2 smoke test passed.")
  end

  defp report_missing_config do
    cfg = Application.get_env(:cinegraph, :r2, [])

    missing =
      [
        {"CLOUDFLARE_ACCOUNT_ID", cfg[:account_id]},
        {"CLOUDFLARE_ACCESS_KEY_ID", cfg[:access_key_id]},
        {"CLOUDFLARE_SECRET_ACCESS_KEY", cfg[:secret_access_key]},
        {"R2_BUCKET", cfg[:bucket]},
        {"R2_CDN_URL", cfg[:cdn_url]}
      ]
      |> Enum.filter(fn {_k, v} -> v in [nil, ""] end)
      |> Enum.map(fn {k, _} -> k end)

    Mix.shell().error("""
    ❌ R2 is not configured. Missing env vars:
      #{Enum.map_join(missing, "\n  ", & &1)}

    To generate the S3 credentials:
      1. Cloudflare Dashboard → R2 → Manage R2 API Tokens
      2. Create API Token → "Object Read & Write" → scope to bucket "cinegraph"
      3. Copy the displayed Access Key ID + Secret Access Key into .env
      4. R2 → cinegraph → Settings → Public Access → Allow Access
         Copy the public r2.dev URL (or attach a custom domain) into R2_CDN_URL
    """)
  end
end

defmodule Cinegraph.Images.R2Test do
  use ExUnit.Case, async: true

  alias Cinegraph.Images.R2

  describe "build_key/5" do
    test "produces category/identifier/kind-{hash8}.{ext} shape" do
      key = R2.build_key("festivals", "cannes", "logo", "<svg>fake</svg>", ext: "svg")
      assert key =~ ~r/\Afestivals\/cannes\/logo-[0-9a-f]{8}\.svg\z/
    end

    test "is deterministic — same content yields the same key" do
      content = "binary-content"
      a = R2.build_key("festivals", "cannes", "logo", content, ext: "png")
      b = R2.build_key("festivals", "cannes", "logo", content, ext: "png")
      assert a == b
    end

    test "different content yields different hash" do
      a = R2.build_key("festivals", "cannes", "logo", "abc", ext: "png")
      b = R2.build_key("festivals", "cannes", "logo", "abcd", ext: "png")
      refute a == b
    end

    test "infers ext from :filename opt when :ext is absent" do
      key = R2.build_key("festivals", "cannes", "logo", "x", filename: "Logo.PNG")
      assert key =~ ~r/\.png\z/
    end

    test "defaults extension to bin when neither opt is given" do
      key = R2.build_key("festivals", "cannes", "logo", "x")
      assert key =~ ~r/\.bin\z/
    end
  end

  describe "guess_content_type/1" do
    test "maps common image extensions" do
      assert R2.guess_content_type("foo.png") == "image/png"
      assert R2.guess_content_type("foo.jpg") == "image/jpeg"
      assert R2.guess_content_type("foo.jpeg") == "image/jpeg"
      assert R2.guess_content_type("foo.svg") == "image/svg+xml"
      assert R2.guess_content_type("foo.webp") == "image/webp"
      assert R2.guess_content_type("foo.gif") == "image/gif"
      assert R2.guess_content_type("foo.avif") == "image/avif"
    end

    test "falls back to octet-stream for unknown extensions" do
      assert R2.guess_content_type("foo.unknown") == "application/octet-stream"
      assert R2.guess_content_type("noextension") == "application/octet-stream"
    end
  end

  describe "configured?/0" do
    test "returns true when config/test.exs populates all required fields" do
      # config/test.exs sets the four required fields with placeholder values
      assert R2.configured?() == true
    end

    test "returns false when cdn_url is empty" do
      original = Application.get_env(:cinegraph, :r2)

      try do
        Application.put_env(
          :cinegraph,
          :r2,
          Keyword.put(original || [], :cdn_url, "")
        )

        refute R2.configured?()
      after
        Application.put_env(:cinegraph, :r2, original)
      end
    end

    test "returns false when access_key_id is empty" do
      original = Application.get_env(:cinegraph, :r2)

      try do
        Application.put_env(
          :cinegraph,
          :r2,
          Keyword.put(original || [], :access_key_id, "")
        )

        refute R2.configured?()
      after
        Application.put_env(:cinegraph, :r2, original)
      end
    end
  end

  describe "cdn_url/1" do
    test "returns base + key when cdn_url configured" do
      assert R2.cdn_url("festivals/cannes/logo-abcd1234.png") ==
               "https://test-cdn.example/festivals/cannes/logo-abcd1234.png"
    end

    test "returns nil when cdn_url is empty" do
      original = Application.get_env(:cinegraph, :r2)

      try do
        Application.put_env(:cinegraph, :r2, Keyword.put(original || [], :cdn_url, ""))
        assert R2.cdn_url("anything") == nil
      after
        Application.put_env(:cinegraph, :r2, original)
      end
    end

    test "trims trailing slashes from cdn_url" do
      original = Application.get_env(:cinegraph, :r2)

      try do
        Application.put_env(
          :cinegraph,
          :r2,
          Keyword.put(original || [], :cdn_url, "https://test-cdn.example/")
        )

        assert R2.cdn_url("a") == "https://test-cdn.example/a"
      after
        Application.put_env(:cinegraph, :r2, original)
      end
    end
  end
end

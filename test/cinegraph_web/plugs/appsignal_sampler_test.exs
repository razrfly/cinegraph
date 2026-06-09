defmodule CinegraphWeb.Plugs.AppsignalSamplerTest do
  use ExUnit.Case, async: true

  import Plug.Test, only: [conn: 3]
  import Plug.Conn, only: [put_req_header: 3]

  alias CinegraphWeb.Plugs.AppsignalSampler

  @on [enabled: true, sample_rate: 1.0]

  defp request(path, ua) do
    c = conn(:get, path, nil)
    if ua, do: put_req_header(c, "user-agent", ua), else: c
  end

  @real_browser "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36"

  describe "decision/2 — master switch" do
    test "disabled config tracks everything (even bots)" do
      assert AppsignalSampler.decision(request("/movies/x", "googlebot"), enabled: false) ==
               :track
    end

    test "missing config defaults to tracking (enabled defaults false)" do
      assert AppsignalSampler.decision(request("/movies/x", "googlebot"), []) == :track
    end
  end

  describe "decision/2 — operational surfaces always tracked" do
    for path <- ["/admin", "/admin/oban", "/api/graphql", "/health", "/health/db"] do
      test "#{path} is tracked even with a bot UA" do
        assert AppsignalSampler.decision(request(unquote(path), "googlebot"), @on) == :track
      end
    end
  end

  describe "decision/2 — bot filtering on public paths" do
    test "known bots are ignored" do
      for ua <- ~w(googlebot bingbot ahrefsbot gptbot claudebot curl python-requests scrapy) do
        assert AppsignalSampler.decision(request("/movies/x", ua), @on) == :ignore,
               "expected #{ua} to be ignored"
      end
    end

    test "empty and missing User-Agent are ignored" do
      assert AppsignalSampler.decision(request("/movies/x", ""), @on) == :ignore
      assert AppsignalSampler.decision(request("/movies/x", nil), @on) == :ignore
    end

    test "real browser on a public path is tracked when sample_rate is 1.0" do
      assert AppsignalSampler.decision(request("/movies/x", @real_browser), @on) == :track
    end
  end

  describe "decision/2 — sampling bounds for anonymous non-bot traffic" do
    test "sample_rate 0.0 ignores a real-browser anonymous request" do
      cfg = [enabled: true, sample_rate: 0.0]
      assert AppsignalSampler.decision(request("/movies/x", @real_browser), cfg) == :ignore
    end

    test "sample_rate 1.0 tracks a real-browser anonymous request" do
      assert AppsignalSampler.decision(request("/movies/x", @real_browser), @on) == :track
    end

    test "operational surfaces are never sampled, even at sample_rate 0.0" do
      cfg = [enabled: true, sample_rate: 0.0]
      assert AppsignalSampler.decision(request("/admin", @real_browser), cfg) == :track
    end
  end

  describe "filterable_path?/1" do
    test "public content routes are filterable" do
      assert AppsignalSampler.filterable_path?("/movies/fight-club-1999")
      assert AppsignalSampler.filterable_path?("/people/brad-pitt")
    end

    test "operational prefixes are excluded (and not matched by mere prefix collision)" do
      refute AppsignalSampler.filterable_path?("/admin")
      refute AppsignalSampler.filterable_path?("/admin/oban")
      refute AppsignalSampler.filterable_path?("/api/graphql")
      refute AppsignalSampler.filterable_path?("/health")
      # "/apirator" must NOT be treated as under "/api"
      assert AppsignalSampler.filterable_path?("/apirator")
    end
  end

  describe "call/2 — always returns the conn unchanged" do
    test "tracked path passes through" do
      c = request("/movies/x", @real_browser)
      assert AppsignalSampler.call(c, AppsignalSampler.init([])) == c
    end

    test "ignored path passes through (Tracer.ignore/0 is a no-op in test)" do
      Application.put_env(:cinegraph, AppsignalSampler, @on)

      on_exit(fn ->
        Application.put_env(:cinegraph, AppsignalSampler, enabled: false, sample_rate: 1.0)
      end)

      c = request("/movies/x", "googlebot")
      assert AppsignalSampler.call(c, AppsignalSampler.init([])) == c
    end
  end
end

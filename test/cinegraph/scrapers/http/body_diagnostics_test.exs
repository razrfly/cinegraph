defmodule Cinegraph.Scrapers.Http.BodyDiagnosticsTest do
  use ExUnit.Case, async: true

  alias Cinegraph.Scrapers.Http.BodyDiagnostics

  @imdb_url "https://www.imdb.com/list/ls053182933/?sort=list_order,asc&start=1&mode=detail"

  test "403 Forbidden HTML returns blocked error" do
    html =
      "<html><head><title>403 Forbidden</title></head><body><h1>403 Forbidden</h1></body></html>"

    assert {:blocked, :forbidden, diagnostics} = BodyDiagnostics.blocked_error(@imdb_url, html)
    assert diagnostics.body_classification == "blocked_403"
    assert diagnostics.title_link_count == 0
  end

  test "captcha and access denied HTML returns challenge error" do
    html = "<html><title>Access Denied</title><body>Captcha robot check required</body></html>"

    assert {:blocked, :challenge, diagnostics} = BodyDiagnostics.blocked_error(@imdb_url, html)
    assert diagnostics.body_classification == "blocked_challenge"
  end

  test "tiny IMDb list HTML with no title links returns non-list error" do
    html = "<html><body>Not a list</body></html>"

    assert {:blocked, :non_list_html, diagnostics} =
             BodyDiagnostics.blocked_error(@imdb_url, html)

    assert diagnostics.body_classification == "imdb_non_list_html"
  end

  test "valid IMDb list HTML succeeds" do
    html = """
    <html>
      <head><title>IMDb List</title></head>
      <body>
        <li class="ipc-metadata-list-summary-item">
          <a href="/title/tt0073629/">The Rocky Horror Picture Show</a>
        </li>
      </body>
    </html>
    """

    assert {:ok, diagnostics} = BodyDiagnostics.blocked_error(@imdb_url, html)

    assert diagnostics.body_classification == "imdb_list_html"
    assert diagnostics.title_link_count == 1
  end

  test "non-IMDb tiny HTML is not rejected by IMDb-list-specific rule" do
    html = "<html><body>ok</body></html>"

    assert {:ok, diagnostics} = BodyDiagnostics.blocked_error("https://example.com/", html)

    assert diagnostics.body_classification == "tiny_html"
  end

  test "origin errors take precedence over IMDb non-list HTML" do
    html = "<html><body>Not found</body></html>"

    assert {:blocked, :origin_error, diagnostics} =
             BodyDiagnostics.blocked_error(@imdb_url, html, pc_status: 404)

    assert diagnostics.body_classification == "origin_error"
  end
end

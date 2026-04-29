defmodule CinegraphWeb.NeutralDesign.PosterSvg do
  @moduledoc """
  Deterministic SVG poster + avatar generators for the Cinegraph Neutral
  design preview.

  Ports the `poster()` and `avatar()` functions from
  `tmp/cinegraph-design/cinegraph/project/cinegraph-components.jsx`.

  Each film maps deterministically (via id-string char-sum modulo) to one of
  6 palettes × 4 layout templates. Output is a `data:image/svg+xml,...`
  URI ready for `<img src=...>`.
  """

  @poster_palettes [
    %{bg: "#1c1a16", hi: "#c8a66a", txt: "#ece7d6"},
    %{bg: "#23303a", hi: "#d6b88a", txt: "#eef0ea"},
    %{bg: "#3a2a25", hi: "#c2766a", txt: "#f0e4dc"},
    %{bg: "#1f2a26", hi: "#9bb39a", txt: "#e9efe7"},
    %{bg: "#15171a", hi: "#a3b3c4", txt: "#e7eaee"},
    %{bg: "#2c2722", hi: "#d4c08a", txt: "#eee6d4"}
  ]

  @avatar_palettes [
    %{bg: "#dad3c2", fg: "#3a342a"},
    %{bg: "#c9d3d9", fg: "#2c3a44"},
    %{bg: "#d5cfc1", fg: "#3a2f24"},
    %{bg: "#cfd6cb", fg: "#2c3a30"},
    %{bg: "#dccfc8", fg: "#3a2c28"}
  ]

  @doc """
  Returns a `data:image/svg+xml,...` URI for the given film map.
  Deterministic: same id always produces the same poster.
  """
  def poster(film) do
    seed = seed_from_id(film.id)
    palette = Enum.at(@poster_palettes, rem(seed, length(@poster_palettes)))
    template = rem(seed, 4)

    lines = wrap_title(film.title)
    font_size = font_size_for(lines)

    svg = poster_svg(template, palette, lines, font_size, film, seed)
    to_data_uri(svg)
  end

  @doc """
  Returns a `data:image/svg+xml,...` URI for the given person map.
  Renders an initials monogram on a tinted background.
  """
  def avatar(person) do
    seed = seed_from_id(person.id)
    palette = Enum.at(@avatar_palettes, rem(seed, length(@avatar_palettes)))
    initials = initials(person.name)

    svg = """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">\
    <rect width="100" height="100" fill="#{palette.bg}"/>\
    <circle cx="50" cy="38" r="16" fill="#{palette.fg}" opacity=".55"/>\
    <ellipse cx="50" cy="86" rx="30" ry="22" fill="#{palette.fg}" opacity=".55"/>\
    <text x="50" y="56" text-anchor="middle" fill="#{palette.bg}" font-family="ui-sans-serif" font-weight="700" font-size="34">#{esc(initials)}</text>\
    </svg>\
    """

    to_data_uri(svg)
  end

  # ─── Internal helpers ──────────────────────────────────────────────

  # Matches JS: [...id].reduce((a,c)=>a+c.charCodeAt(0),0)
  # Must use codepoints (not bytes) to match JS char codes exactly.
  defp seed_from_id(id) when is_binary(id) do
    id
    |> String.to_charlist()
    |> Enum.sum()
  end

  defp seed_from_id(id) when is_integer(id), do: id

  defp seed_from_id(_), do: 0

  # Matches the JS title-wrapping logic (lines longer than 12 chars wrap)
  defp wrap_title(title) do
    words = String.split(title, ~r/\s+/, trim: true)

    {lines, current} =
      Enum.reduce(words, {[], ""}, fn word, {acc, cur} ->
        candidate = if cur == "", do: word, else: cur <> " " <> word

        cond do
          String.length(candidate) > 12 and cur != "" ->
            {acc ++ [cur], word}

          true ->
            {acc, candidate}
        end
      end)

    if current == "", do: lines, else: lines ++ [current]
  end

  defp font_size_for(lines) do
    case length(lines) do
      n when n > 2 -> 56
      2 -> 78
      _ -> 110
    end
  end

  defp initials(name) do
    name
    |> String.split(~r/\s+/, trim: true)
    |> Enum.map(&String.first/1)
    |> Enum.take(2)
    |> Enum.join("")
  end

  # Template 0: Top accent bar + year/genre row + title block + director footer
  defp poster_svg(0, p, lines, fs, film, _seed) do
    """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 600 900" preserveAspectRatio="xMidYMid slice">\
    <rect width="600" height="900" fill="#{p.bg}"/>\
    <rect x="0" y="0" width="600" height="6" fill="#{p.hi}"/>\
    <text x="40" y="58" fill="#{p.hi}" font-family="ui-sans-serif, -apple-system, sans-serif" font-weight="700" font-size="13" letter-spacing="6">#{film.year}  ·  #{esc(String.upcase(List.first(film.genre || []) || ""))}</text>\
    #{title_lines(lines, fs, p.txt, 360, "start", 40, true)}\
    <rect x="40" y="#{round(390 + length(lines) * fs * 0.95)}" width="80" height="2" fill="#{p.hi}"/>\
    <text x="40" y="850" fill="#{p.txt}" opacity=".75" font-family="ui-sans-serif" font-weight="700" font-size="14" letter-spacing="3">DIR. #{esc(String.upcase(film.dir))}</text>\
    </svg>\
    """
  end

  # Template 1: Centered circle + centered title + centered director/year
  defp poster_svg(1, p, lines, fs, film, _seed) do
    """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 600 900" preserveAspectRatio="xMidYMid slice">\
    <rect width="600" height="900" fill="#{p.bg}"/>\
    <circle cx="300" cy="280" r="180" fill="#{p.hi}" opacity=".85"/>\
    <circle cx="300" cy="280" r="180" fill="none" stroke="#{p.txt}" stroke-width="1" opacity=".4"/>\
    #{title_lines(lines, fs, p.txt, 600, "middle", 300, true)}\
    <text x="300" y="840" text-anchor="middle" fill="#{p.hi}" font-family="ui-sans-serif" font-weight="700" font-size="14" letter-spacing="3">#{esc(String.upcase(film.dir))} · #{film.year}</text>\
    </svg>\
    """
  end

  # Template 2: Top tinted band + cinegraph stamp + title block + director
  defp poster_svg(2, p, lines, fs, film, seed) do
    no = rem(seed, 999) + 100

    """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 600 900" preserveAspectRatio="xMidYMid slice">\
    <rect width="600" height="900" fill="#{p.bg}"/>\
    <rect x="0" y="0" width="600" height="380" fill="#{p.hi}" opacity=".22"/>\
    <rect x="0" y="378" width="600" height="2" fill="#{p.hi}"/>\
    <text x="40" y="60" fill="#{p.txt}" opacity=".7" font-family="ui-sans-serif" font-weight="600" font-size="12" letter-spacing="5">CINEGRAPH · № #{no}</text>\
    #{title_lines(lines, fs, p.txt, 500, "start", 40, true)}\
    <text x="40" y="850" fill="#{p.hi}" font-family="ui-sans-serif" font-weight="700" font-size="13" letter-spacing="3">DIR. #{esc(String.upcase(film.dir))}</text>\
    </svg>\
    """
  end

  # Template 3: Diagonal accent + year + title block + director
  defp poster_svg(3, p, lines, fs, film, _seed) do
    """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 600 900" preserveAspectRatio="xMidYMid slice">\
    <rect width="600" height="900" fill="#{p.bg}"/>\
    <polygon points="0,720 600,540 600,900 0,900" fill="#{p.hi}" opacity=".25"/>\
    <polygon points="0,900 600,660 600,900" fill="#{p.hi}" opacity=".4"/>\
    <text x="40" y="60" fill="#{p.txt}" opacity=".55" font-family="ui-sans-serif" font-weight="700" font-size="12" letter-spacing="4">#{film.year}</text>\
    #{title_lines(lines, fs, p.txt, 500, "start", 40, true, 0.92)}\
    <text x="40" y="855" fill="#{p.txt}" opacity=".8" font-family="ui-sans-serif" font-weight="700" font-size="13" letter-spacing="3">DIR. #{esc(String.upcase(film.dir))}</text>\
    </svg>\
    """
  end

  defp title_lines(lines, fs, color, base_y, anchor, x, italic, line_factor \\ 0.95) do
    italic_attr = if italic, do: ~s( font-style="italic"), else: ""

    lines
    |> Enum.with_index()
    |> Enum.map(fn {line, i} ->
      y = round(base_y + i * fs * line_factor)

      ~s(<text x="#{x}" y="#{y}" text-anchor="#{anchor}" fill="#{color}" font-family="Georgia, 'Times New Roman', serif" font-size="#{fs}"#{italic_attr}>#{esc(line)}</text>)
    end)
    |> Enum.join("")
  end

  defp esc(s) do
    s
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  defp to_data_uri(svg) do
    "data:image/svg+xml;utf8," <> URI.encode(svg)
  end
end

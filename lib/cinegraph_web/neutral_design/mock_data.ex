defmodule CinegraphWeb.NeutralDesign.MockData do
  @moduledoc """
  Mock data for the Cinegraph Neutral design preview.

  1:1 port of `tmp/cinegraph-design/cinegraph/project/cinegraph-data.js`.
  Used by `CinegraphWeb.DesignPreviewController` to render the design without
  any database dependency. Phase 2 will swap these for real Cinegraph queries.
  """

  def films do
    [
      %{
        id: "oppen",
        title: "Oppenheimer",
        year: 2023,
        rated: "R",
        runtime: 180,
        genre: ["Drama", "Thriller"],
        dir: "Christopher Nolan",
        cast: ["Cillian Murphy", "Robert Downey Jr.", "Emily Blunt", "Florence Pugh"],
        pop: 94,
        crit: 94,
        cult: 92,
        ppl: 92,
        oscars: 7,
        collections: ["1001 Movies", "Best Picture Winners"],
        updated_days: 2,
        delta: 3
      },
      %{
        id: "parasite",
        title: "Parasite",
        year: 2019,
        rated: "R",
        runtime: 132,
        genre: ["Thriller", "Drama"],
        dir: "Bong Joon-ho",
        cast: ["Song Kang-ho", "Lee Sun-kyun", "Cho Yeo-jeong", "Choi Woo-shik"],
        pop: 92,
        crit: 98,
        cult: 96,
        ppl: 86,
        oscars: 4,
        collections: ["1001 Movies", "Best Picture Winners", "Cannes"],
        updated_days: 5,
        delta: 1
      },
      %{
        id: "eeaao",
        title: "Everything Everywhere All At Once",
        year: 2022,
        rated: "R",
        runtime: 139,
        genre: ["Sci-Fi", "Comedy"],
        dir: "Daniels",
        cast: ["Michelle Yeoh", "Ke Huy Quan", "Jamie Lee Curtis", "Stephanie Hsu"],
        pop: 90,
        crit: 95,
        cult: 94,
        ppl: 80,
        oscars: 7,
        collections: ["Best Picture Winners", "A24 Essentials"],
        updated_days: 3,
        delta: 0
      },
      %{
        id: "moonlight",
        title: "Moonlight",
        year: 2016,
        rated: "R",
        runtime: 111,
        genre: ["Drama", "Romance"],
        dir: "Barry Jenkins",
        cast: ["Trevante Rhodes", "Mahershala Ali", "Naomie Harris", "Janelle Monáe"],
        pop: 72,
        crit: 98,
        cult: 92,
        ppl: 82,
        oscars: 3,
        collections: ["1001 Movies", "Best Picture Winners", "A24 Essentials"],
        updated_days: 14,
        delta: 2
      },
      %{
        id: "dune2",
        title: "Dune: Part Two",
        year: 2024,
        rated: "PG-13",
        runtime: 166,
        genre: ["Sci-Fi", "Adventure"],
        dir: "Denis Villeneuve",
        cast: ["Timothée Chalamet", "Zendaya", "Rebecca Ferguson", "Javier Bardem"],
        pop: 94,
        crit: 94,
        cult: 88,
        ppl: 88,
        oscars: 2,
        collections: ["Villeneuve Cinematic Universe"],
        updated_days: 1,
        delta: 5
      },
      %{
        id: "pastlives",
        title: "Past Lives",
        year: 2023,
        rated: "PG-13",
        runtime: 105,
        genre: ["Romance", "Drama"],
        dir: "Celine Song",
        cast: ["Greta Lee", "Teo Yoo", "John Magaro"],
        pop: 66,
        crit: 97,
        cult: 78,
        ppl: 66,
        oscars: 0,
        collections: ["A24 Essentials", "Sundance Spotlight"],
        updated_days: 9,
        delta: -1
      },
      %{
        id: "anatomy",
        title: "Anatomy of a Fall",
        year: 2023,
        rated: "R",
        runtime: 151,
        genre: ["Thriller", "Drama"],
        dir: "Justine Triet",
        cast: ["Sandra Hüller", "Swann Arlaud", "Milo Machado-Graner"],
        pop: 62,
        crit: 96,
        cult: 72,
        ppl: 70,
        oscars: 1,
        collections: ["Cannes", "Palme d’Or"],
        updated_days: 6,
        delta: 1
      },
      %{
        id: "zone",
        title: "The Zone of Interest",
        year: 2023,
        rated: "PG-13",
        runtime: 105,
        genre: ["Drama", "War"],
        dir: "Jonathan Glazer",
        cast: ["Christian Friedel", "Sandra Hüller"],
        pop: 38,
        crit: 95,
        cult: 74,
        ppl: 76,
        oscars: 2,
        collections: ["Cannes"],
        updated_days: 7,
        delta: 1
      },
      %{
        id: "anora",
        title: "Anora",
        year: 2024,
        rated: "R",
        runtime: 139,
        genre: ["Drama", "Comedy"],
        dir: "Sean Baker",
        cast: ["Mikey Madison", "Mark Eydelshteyn", "Yuriy Borisov"],
        pop: 72,
        crit: 95,
        cult: 74,
        ppl: 64,
        oscars: 5,
        collections: ["Palme d’Or", "Best Picture Winners"],
        updated_days: 1,
        delta: 8
      },
      %{
        id: "brutalist",
        title: "The Brutalist",
        year: 2024,
        rated: "R",
        runtime: 215,
        genre: ["Drama"],
        dir: "Brady Corbet",
        cast: ["Adrien Brody", "Felicity Jones", "Guy Pearce"],
        pop: 48,
        crit: 94,
        cult: 72,
        ppl: 70,
        oscars: 3,
        collections: ["Venice"],
        updated_days: 2,
        delta: 4
      },
      %{
        id: "wildrobot",
        title: "The Wild Robot",
        year: 2024,
        rated: "PG",
        runtime: 102,
        genre: ["Family", "Animation"],
        dir: "Chris Sanders",
        cast: ["Lupita Nyong’o", "Pedro Pascal", "Kit Connor", "Bill Nighy"],
        pop: 86,
        crit: 96,
        cult: 70,
        ppl: 70,
        oscars: 0,
        collections: ["Animation Picks"],
        updated_days: 8,
        delta: 2
      },
      %{
        id: "killers",
        title: "Killers of the Flower Moon",
        year: 2023,
        rated: "R",
        runtime: 206,
        genre: ["Crime", "Drama"],
        dir: "Martin Scorsese",
        cast: ["Leonardo DiCaprio", "Robert De Niro", "Lily Gladstone"],
        pop: 68,
        crit: 92,
        cult: 82,
        ppl: 94,
        oscars: 0,
        collections: ["Scorsese Filmography"],
        updated_days: 11,
        delta: 0
      },
      %{
        id: "pulp",
        title: "Pulp Fiction",
        year: 1994,
        rated: "R",
        runtime: 154,
        genre: ["Crime", "Drama"],
        dir: "Quentin Tarantino",
        cast: ["John Travolta", "Samuel L. Jackson", "Uma Thurman", "Bruce Willis"],
        pop: 92,
        crit: 97,
        cult: 98,
        ppl: 94,
        oscars: 1,
        collections: ["1001 Movies", "AFI 100", "Palme d’Or"],
        updated_days: 21,
        delta: 0
      },
      %{
        id: "goodfellas",
        title: "Goodfellas",
        year: 1990,
        rated: "R",
        runtime: 145,
        genre: ["Crime", "Drama"],
        dir: "Martin Scorsese",
        cast: ["Robert De Niro", "Ray Liotta", "Joe Pesci", "Lorraine Bracco"],
        pop: 88,
        crit: 96,
        cult: 95,
        ppl: 94,
        oscars: 1,
        collections: ["1001 Movies", "AFI 100", "Scorsese Filmography"],
        updated_days: 30,
        delta: 0
      },
      %{
        id: "silence",
        title: "The Silence of the Lambs",
        year: 1991,
        rated: "R",
        runtime: 118,
        genre: ["Thriller", "Crime"],
        dir: "Jonathan Demme",
        cast: ["Jodie Foster", "Anthony Hopkins", "Scott Glenn", "Ted Levine"],
        pop: 87,
        crit: 96,
        cult: 95,
        ppl: 92,
        oscars: 5,
        collections: ["1001 Movies", "AFI 100", "Best Picture Winners"],
        updated_days: 45,
        delta: 0
      },
      %{
        id: "matrix",
        title: "The Matrix",
        year: 1999,
        rated: "R",
        runtime: 136,
        genre: ["Sci-Fi", "Action"],
        dir: "The Wachowskis",
        cast: ["Keanu Reeves", "Laurence Fishburne", "Carrie-Anne Moss"],
        pop: 95,
        crit: 92,
        cult: 98,
        ppl: 84,
        oscars: 4,
        collections: ["1001 Movies", "AFI 100"],
        updated_days: 60,
        delta: 0
      }
    ]
  end

  def people do
    [
      %{
        id: "p_chalamet",
        name: "Timothée Chalamet",
        role: "Actor",
        known_for: ["Dune: Part Two", "Dune", "Wonka"],
        films: 18,
        delta_pct: 22,
        trending: true,
        era: "2010s–2020s"
      },
      %{
        id: "p_zendaya",
        name: "Zendaya",
        role: "Actor",
        known_for: ["Dune: Part Two", "Challengers", "Spider-Man: No Way Home"],
        films: 14,
        delta_pct: 18,
        trending: true,
        era: "2010s–2020s"
      },
      %{
        id: "p_villeneuve",
        name: "Denis Villeneuve",
        role: "Director",
        known_for: ["Dune: Part Two", "Arrival", "Blade Runner 2049"],
        films: 11,
        delta_pct: 12,
        trending: true,
        era: "2010s–2020s"
      },
      %{
        id: "p_song",
        name: "Celine Song",
        role: "Director",
        known_for: ["Past Lives"],
        films: 1,
        delta_pct: 38,
        trending: true,
        era: "2020s"
      },
      %{
        id: "p_yeoh",
        name: "Michelle Yeoh",
        role: "Actor",
        known_for: ["Everything Everywhere All At Once", "Crouching Tiger", "Wicked"],
        films: 46,
        delta_pct: 9,
        trending: false,
        era: "1980s–2020s"
      },
      %{
        id: "p_jenkins",
        name: "Barry Jenkins",
        role: "Director",
        known_for: ["Moonlight", "If Beale Street Could Talk"],
        films: 6,
        delta_pct: 4,
        trending: false,
        era: "2010s–2020s"
      },
      %{
        id: "p_bong",
        name: "Bong Joon-ho",
        role: "Director",
        known_for: ["Parasite", "Memories of Murder", "Snowpiercer"],
        films: 8,
        delta_pct: 6,
        trending: false,
        era: "2000s–2020s"
      },
      %{
        id: "p_scorsese",
        name: "Martin Scorsese",
        role: "Director",
        known_for: ["Goodfellas", "Killers of the Flower Moon", "The Departed"],
        films: 26,
        delta_pct: 2,
        trending: false,
        era: "1970s–2020s"
      },
      %{
        id: "p_huller",
        name: "Sandra Hüller",
        role: "Actor",
        known_for: ["Anatomy of a Fall", "The Zone of Interest", "Toni Erdmann"],
        films: 23,
        delta_pct: 27,
        trending: true,
        era: "2010s–2020s"
      },
      %{
        id: "p_madison",
        name: "Mikey Madison",
        role: "Actor",
        known_for: ["Anora", "Once Upon a Time in Hollywood"],
        films: 8,
        delta_pct: 44,
        trending: true,
        era: "2020s"
      },
      %{
        id: "p_brody",
        name: "Adrien Brody",
        role: "Actor",
        known_for: ["The Brutalist", "The Pianist", "Asteroid City"],
        films: 42,
        delta_pct: 15,
        trending: false,
        era: "1990s–2020s"
      },
      %{
        id: "p_lee",
        name: "Greta Lee",
        role: "Actor",
        known_for: ["Past Lives", "The Morning Show", "Russian Doll"],
        films: 11,
        delta_pct: 19,
        trending: false,
        era: "2010s–2020s"
      }
    ]
  end

  def lists do
    [
      %{
        id: "l_1001",
        name: "1001 Movies You Must See Before You Die",
        curator: "Steven Jay Schneider",
        count: 1219,
        updated: "4d ago",
        accent: "amber"
      },
      %{
        id: "l_a24",
        name: "A24 Essentials",
        curator: "Cinegraph Staff",
        count: 48,
        updated: "1d ago",
        accent: "red"
      },
      %{
        id: "l_palme",
        name: "Palme d’Or Winners",
        curator: "Festival de Cannes",
        count: 77,
        updated: "2w ago",
        accent: "green"
      },
      %{
        id: "l_afi",
        name: "AFI’s 100 Years…100 Movies",
        curator: "American Film Inst.",
        count: 100,
        updated: "1mo ago",
        accent: "amber"
      },
      %{
        id: "l_bp",
        name: "Best Picture Winners",
        curator: "AMPAS",
        count: 96,
        updated: "2mo ago",
        accent: "amber"
      },
      %{
        id: "l_sf",
        name: "Sight & Sound — Greatest of All Time",
        curator: "BFI",
        count: 250,
        updated: "4mo ago",
        accent: "blue"
      },
      %{
        id: "l_anim",
        name: "Animation Picks 2024",
        curator: "Cinegraph Staff",
        count: 24,
        updated: "5d ago",
        accent: "green"
      },
      %{
        id: "l_neo",
        name: "Neo-noir Resurgence",
        curator: "Cinegraph Staff",
        count: 32,
        updated: "2w ago",
        accent: "red"
      }
    ]
  end

  def graph do
    %{
      nodes: [
        %{id: "dune2", label: "Dune: Part Two", type: "film", x: 0.50, y: 0.50, big: true},
        %{id: "villeneuve", label: "D. Villeneuve", type: "person", x: 0.20, y: 0.30, big: false},
        %{id: "arrival", label: "Arrival", type: "film", x: 0.10, y: 0.55, big: false},
        %{id: "br2049", label: "Blade Runner 2049", type: "film", x: 0.18, y: 0.78, big: false},
        %{id: "chalamet", label: "T. Chalamet", type: "person", x: 0.78, y: 0.30, big: false},
        %{id: "wonka", label: "Wonka", type: "film", x: 0.92, y: 0.55, big: false},
        %{id: "cmbyn", label: "Call Me By Your Name", type: "film", x: 0.86, y: 0.78, big: false},
        %{id: "zendaya", label: "Zendaya", type: "person", x: 0.50, y: 0.16, big: false},
        %{id: "challeng", label: "Challengers", type: "film", x: 0.62, y: 0.86, big: false},
        %{id: "ferguson", label: "R. Ferguson", type: "person", x: 0.34, y: 0.86, big: false},
        %{id: "fritz", label: "F. Fraser", type: "person", x: 0.40, y: 0.10, big: false}
      ],
      edges: [
        {"dune2", "villeneuve"},
        {"villeneuve", "arrival"},
        {"villeneuve", "br2049"},
        {"dune2", "chalamet"},
        {"chalamet", "wonka"},
        {"chalamet", "cmbyn"},
        {"dune2", "zendaya"},
        {"zendaya", "challeng"},
        {"dune2", "ferguson"},
        {"dune2", "fritz"}
      ]
    }
  end

  def updates do
    [
      %{
        id: "u1",
        type: :awards,
        text: "Anora won Best Picture, Director, Actress + 2 more",
        ago: "2h"
      },
      %{
        id: "u2",
        type: :data,
        text: "Dune: Part Two cultural-relevance score +5 (festival mentions ↑)",
        ago: "6h"
      },
      %{
        id: "u3",
        type: :release,
        text: "Mickey 17 confirmed for theatrical release — March 7",
        ago: "8h"
      },
      %{
        id: "u4",
        type: :collab,
        text: "Florence Pugh + Christopher Nolan added to upcoming production",
        ago: "1d"
      },
      %{
        id: "u5",
        type: :list,
        text: "Sight & Sound 2030 ballot opened — critic submissions due Sep 1",
        ago: "1d"
      },
      %{
        id: "u6",
        type: :data,
        text: "7,142 new TMDb keywords ingested overnight",
        ago: "2d"
      }
    ]
  end

  def insights do
    %{
      cri: %{
        current: 78.2,
        delta: 1.4,
        label: "Avg. Cultural Relevance",
        sub: "Across 16,420 tracked films"
      },
      awards: %{
        current: 182,
        delta: 12,
        label: "Awards events tracked",
        sub: "Sundance → Oscars season"
      },
      people: %{
        current: 48_923,
        delta: 417,
        label: "People in graph",
        sub: "Cast + crew + critics"
      },
      canon: %{
        current: 6,
        delta: 0,
        label: "Canon lists synced",
        sub: "Live: 1001, AFI, BFI, Cannes, AMPAS"
      }
    }
  end

  def genres do
    [
      "All",
      "Drama",
      "Thriller",
      "Sci-Fi",
      "Comedy",
      "Romance",
      "Documentary",
      "Animation",
      "Horror",
      "Crime",
      "Family"
    ]
  end
end

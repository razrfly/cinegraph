defmodule CinegraphWeb.DirectorLive.Show do
  use CinegraphWeb, :live_view

  alias Cinegraph.People
  alias Cinegraph.Collaborations
  import CinegraphWeb.CollaborationComponents

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket}
  end

  @impl true
  def handle_params(%{"id" => id}, _url, socket) do
    case People.get_person_with_credits(id) do
      nil ->
        socket =
          socket
          |> put_flash(:error, "Person not found")
          |> push_navigate(to: ~p"/people")

        {:noreply, socket}

      director ->
        # Verify this person is actually a director
        is_director =
          director.known_for_department == "Directing" ||
            Enum.any?(director.crew_credits, &(&1.job == "Director"))

        if is_director do
          socket =
            socket
            |> assign(:page_title, "Director Analysis: #{director.name}")
            |> assign(:director, director)
            |> assign(:director_stats, get_director_stats(director))
            |> assign(:frequent_actors, get_frequent_actors(id))
            |> assign(:genre_analysis, analyze_genres(director))
            |> assign(:rating_trends, get_rating_trends(director))
            |> assign(:box_office_trends, get_box_office_trends(director))
            |> assign(:collaboration_network, get_collaboration_network(id))

          {:noreply, socket}
        else
          socket =
            socket
            |> put_flash(:error, "This person is not a director")
            |> push_navigate(to: ~p"/people/#{id}")

          {:noreply, socket}
        end
    end
  end

  # Private functions

  defp get_director_stats(director) do
    directing_credits = Enum.filter(director.crew_credits, &(&1.job == "Director"))
    movies = Enum.map(directing_credits, & &1.movie) |> Enum.uniq_by(& &1.id)

    total_revenue = Enum.sum(Enum.map(movies, &(Map.get(&1, :revenue, 0))))
    avg_rating = calculate_average_rating(movies)

    %{
      total_films: length(movies),
      total_revenue: total_revenue,
      avg_revenue: if(length(movies) > 0, do: div(total_revenue, length(movies)), else: 0),
      avg_rating: avg_rating,
      highest_rated: Enum.max_by(movies, &(Cinegraph.Movies.Movie.vote_average(&1) || 0), fn -> nil end),
      highest_grossing: Enum.max_by(movies, &(Map.get(&1, :revenue, 0)), fn -> nil end),
      years_active: calculate_years_active(movies)
    }
  end

  defp get_frequent_actors(director_id) do
    Collaborations.find_director_frequent_actors(director_id, limit: 15)
    |> Enum.map(fn result ->
      # Add collaboration strength
      strength =
        cond do
          result.movie_count >= 5 -> :very_strong
          result.movie_count >= 3 -> :strong
          true -> :moderate
        end

      Map.put(result, :strength, strength)
    end)
  end

  defp analyze_genres(director) do
    directing_credits = Enum.filter(director.crew_credits, &(&1.job == "Director"))
    movies = Enum.map(directing_credits, & &1.movie)

    # Get genre distribution
    genre_counts =
      movies
      |> Enum.flat_map(fn movie ->
        # In a real app, you'd fetch genres from movie_genres table
        # For now, we'll simulate with a simple categorization
        categorize_movie_genres(movie)
      end)
      |> Enum.frequencies()
      |> Enum.sort_by(fn {_genre, count} -> count end, :desc)
      |> Enum.take(5)

    # Calculate genre performance
    genre_performance =
      Enum.map(genre_counts, fn {genre, count} ->
        genre_movies =
          Enum.filter(movies, fn movie ->
            Enum.member?(categorize_movie_genres(movie), genre)
          end)

        avg_rating = calculate_average_rating(genre_movies)
        total_revenue = Enum.sum(Enum.map(genre_movies, &(Map.get(&1, :revenue, 0))))

        %{
          genre: genre,
          count: count,
          avg_rating: avg_rating,
          total_revenue: total_revenue
        }
      end)

    %{
      genre_counts: genre_counts,
      genre_performance: genre_performance,
      primary_genre: if(length(genre_counts) > 0, do: elem(hd(genre_counts), 0), else: nil)
    }
  end

  defp categorize_movie_genres(movie) do
    # Simple genre categorization based on movie attributes
    # In a real app, this would come from the movie_genres table
    cond do
      String.contains?(String.downcase(movie.title || ""), ["war", "battle"]) ->
        ["War", "Drama"]

      String.contains?(String.downcase(movie.title || ""), ["love", "romance"]) ->
        ["Romance", "Drama"]

      String.contains?(String.downcase(movie.title || ""), ["space", "alien"]) ->
        ["Sci-Fi", "Adventure"]

      movie.runtime && movie.runtime > 150 ->
        ["Drama", "Epic"]

      true ->
        ["Drama"]
    end
  end

  defp get_rating_trends(director) do
    directing_credits =
      director.crew_credits
      |> Enum.filter(&(&1.job == "Director"))
      |> Enum.sort_by(& &1.movie.release_date)

    movies_with_ratings =
      directing_credits
      |> Enum.map(& &1.movie)
      |> Enum.filter(&(Cinegraph.Movies.Movie.vote_average(&1) && &1.release_date))

    if length(movies_with_ratings) > 0 do
      # Group by decade
      by_decade =
        movies_with_ratings
        |> Enum.group_by(fn movie ->
          decade = div(movie.release_date.year, 10) * 10
          "#{decade}s"
        end)
        |> Enum.map(fn {decade, movies} ->
          %{
            decade: decade,
            avg_rating: calculate_average_rating(movies),
            film_count: length(movies)
          }
        end)
        |> Enum.sort_by(& &1.decade)

      %{
        by_decade: by_decade,
        trend: calculate_trend(movies_with_ratings),
        recent_performance: calculate_recent_performance(movies_with_ratings)
      }
    else
      %{by_decade: [], trend: :stable, recent_performance: nil}
    end
  end

  defp get_box_office_trends(director) do
    directing_credits =
      director.crew_credits
      |> Enum.filter(&(&1.job == "Director"))
      |> Enum.sort_by(& &1.movie.release_date)

    movies_with_revenue =
      directing_credits
      |> Enum.map(& &1.movie)
      |> Enum.filter(&(Map.get(&1, :revenue) && Map.get(&1, :revenue) > 0 && &1.release_date))

    if length(movies_with_revenue) > 0 do
      # Calculate cumulative box office
      cumulative =
        movies_with_revenue
        |> Enum.scan(%{year: nil, total: 0}, fn movie, acc ->
          %{
            year: movie.release_date.year,
            total: acc.total + Map.get(movie, :revenue, 0),
            movie: movie.title
          }
        end)

      %{
        cumulative_revenue: cumulative,
        highest_year: find_highest_revenue_year(movies_with_revenue),
        average_per_film:
          div(Enum.sum(Enum.map(movies_with_revenue, &Map.get(&1, :revenue, 0))), length(movies_with_revenue))
      }
    else
      %{cumulative_revenue: [], highest_year: nil, average_per_film: 0}
    end
  end

  defp get_collaboration_network(director_id) do
    # Get key crew members this director works with frequently
    query = """
    SELECT 
      p.id,
      p.name,
      c2.job,
      c2.department,
      COUNT(DISTINCT c1.movie_id) as collaborations,
      AVG(m.vote_average) as avg_rating
    FROM credits c1
    JOIN credits c2 ON c1.movie_id = c2.movie_id AND c1.person_id != c2.person_id
    JOIN people p ON c2.person_id = p.id
    JOIN movies m ON c1.movie_id = m.id
    WHERE c1.person_id = $1 
      AND c1.job = 'Director'
      AND c2.department IN ('Writing', 'Camera', 'Editing', 'Sound', 'Production')
    GROUP BY p.id, p.name, c2.job, c2.department
    HAVING COUNT(DISTINCT c1.movie_id) >= 2
    ORDER BY collaborations DESC
    LIMIT 20
    """

    director_id_int =
      if is_binary(director_id), do: String.to_integer(director_id), else: director_id

    case Cinegraph.Repo.query(query, [director_id_int]) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [id, name, job, department, collaborations, avg_rating] ->
          %{
            person: %{id: id, name: name},
            job: job,
            department: department,
            collaborations: collaborations,
            avg_rating: avg_rating && Float.round(avg_rating, 1)
          }
        end)

      _ ->
        []
    end
  end

  # Helper functions

  defp calculate_average_rating(movies) do
    ratings =
      movies
      |> Enum.map(&Cinegraph.Movies.Movie.vote_average/1)
      |> Enum.reject(&is_nil/1)

    if length(ratings) > 0 do
      Float.round(Enum.sum(ratings) / length(ratings), 1)
    else
      nil
    end
  end

  defp calculate_years_active(movies) do
    dates =
      movies
      |> Enum.map(& &1.release_date)
      |> Enum.reject(&is_nil/1)

    if length(dates) > 0 do
      min_date = Enum.min(dates, Date)
      max_date = Enum.max(dates, Date)

      %{
        first_film: min_date,
        latest_film: max_date,
        years: max_date.year - min_date.year + 1
      }
    else
      %{first_film: nil, latest_film: nil, years: 0}
    end
  end

  defp calculate_trend(movies_with_ratings) do
    # Simple trend calculation based on recent vs older films
    recent = Enum.filter(movies_with_ratings, &(&1.release_date.year >= 2015))
    older = Enum.filter(movies_with_ratings, &(&1.release_date.year < 2015))

    if length(recent) > 0 && length(older) > 0 do
      recent_avg = calculate_average_rating(recent)
      older_avg = calculate_average_rating(older)

      cond do
        recent_avg > older_avg + 0.5 -> :improving
        recent_avg < older_avg - 0.5 -> :declining
        true -> :stable
      end
    else
      :stable
    end
  end

  defp calculate_recent_performance(movies) do
    recent =
      movies
      |> Enum.filter(&(&1.release_date.year >= Date.utc_today().year - 5))
      |> Enum.take(-3)

    if length(recent) > 0 do
      %{
        films: length(recent),
        avg_rating: calculate_average_rating(recent)
      }
    else
      nil
    end
  end

  defp find_highest_revenue_year(movies) do
    movies
    |> Enum.group_by(& &1.release_date.year)
    |> Enum.map(fn {year, year_movies} ->
      {year, Enum.sum(Enum.map(year_movies, &Map.get(&1, :revenue, 0)))}
    end)
    |> Enum.max_by(fn {_year, revenue} -> revenue end, fn -> {nil, 0} end)
    |> elem(0)
  end
end

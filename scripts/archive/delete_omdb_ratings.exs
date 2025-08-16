alias Cinegraph.{Repo, ExternalSources.Rating, ExternalSources.Source}
import Ecto.Query

omdb_source = Repo.get_by!(Source, name: "OMDb")
{count, _} = from(r in Rating, where: r.source_id == ^omdb_source.id) |> Repo.delete_all()
IO.puts("Deleted #{count} OMDb ratings")
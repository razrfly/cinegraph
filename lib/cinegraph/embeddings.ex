defmodule Cinegraph.Embeddings do
  @moduledoc """
  Local sentence-embedding inference for Lever E (#1070) — plot/overview text → dense vectors.

  Wraps a Bumblebee sentence-transformer served through the existing EXLA stack (no per-call cost,
  no external API, multilingual-capable). The serving is built once and memoized in
  `:persistent_term` so repeated `embed/1` calls reuse the compiled model.

  Default model: `sentence-transformers/all-MiniLM-L6-v2` (384-dim, ~90MB, mean-pooled, L2-normalized
  — so cosine similarity is a plain dot product). Override with `EMBEDDING_MODEL`.

  First call downloads the model from the HuggingFace hub into the Bumblebee cache.
  """

  @default_model "sentence-transformers/all-MiniLM-L6-v2"
  @key {__MODULE__, :serving}

  @doc "The active model repo id."
  def model, do: System.get_env("EMBEDDING_MODEL", @default_model)

  @doc "Embed a list of texts → list of 384-d float lists (L2-normalized). Batched by the serving."
  def embed(texts) when is_list(texts) do
    serving()
    |> Nx.Serving.run(texts)
    |> Enum.map(fn %{embedding: e} -> Nx.to_list(e) end)
  end

  @doc "Embed → a single {n, dim} Nx tensor (rows aligned to `texts`)."
  def embed_tensor(texts) when is_list(texts) do
    serving()
    |> Nx.Serving.run(texts)
    |> Enum.map(& &1.embedding)
    |> Nx.stack()
  end

  @doc "Build (once) + memoize the Bumblebee text-embedding serving."
  def serving do
    case :persistent_term.get(@key, nil) do
      nil ->
        s = build_serving()
        :persistent_term.put(@key, s)
        s

      s ->
        s
    end
  end

  defp build_serving do
    repo = {:hf, model()}
    {:ok, model_info} = Bumblebee.load_model(repo)
    {:ok, tokenizer} = Bumblebee.load_tokenizer(repo)

    Bumblebee.Text.text_embedding(model_info, tokenizer,
      output_pool: :mean_pooling,
      output_attribute: :hidden_state,
      embedding_processor: :l2_norm,
      compile: [batch_size: 64, sequence_length: 128],
      defn_options: [compiler: EXLA]
    )
  end
end

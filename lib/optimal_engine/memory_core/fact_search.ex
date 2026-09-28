defmodule OptimalEngine.MemoryCore.FactSearch do
  @moduledoc """
  Zoeken in de gekeurde, geldende feiten van een werkruimte: op betekenis
  (vector) én op woorden (BM25), met terugval op alleen woorden als de
  embedder weg is.

  Waarom (gemeten 27-09): search en rag zochten in memories en claimbronnen,
  niet in de feiten die de zaak keurt, en de embedder was onbereikbaar. Een
  gastvraag als "kan ik een high tea doen op een dinsdag in november" vond het
  feit daardoor niet.

  Wat telt als feit: `lifecycle_state = 'accepted'`, open transactietijd (dus
  niet vervangen of ingetrokken) en niet verlopen (`stale_after` leeg of in de
  toekomst, dezelfde regel als de governed recall). Kandidaten, verworpen
  claims en andere werkruimten doen niet mee.

  De zoekvraag wordt nergens weggeschreven: geen search-event, geen context
  package, geen ledger, geen model_call_run. De vraag gaat alleen naar de
  embedder en blijft verder in het geheugen van dit verzoek.

  ## Score

  score = w · vector + (1 − w) · woorden, met w = `vector_weight` (0,7). De
  vectorpoot is de cosinus, min-max geschaald over de geldende feiten; de
  woordpoot is BM25 gedeeld door de hoogste BM25 van deze vraag. Gemeten 28-09
  op de 776 geldende RH-feiten met nomic-embed-text en tien gastvragen: 9 van
  10 het juiste feit in de top 3 (alleen vector 8, alleen BM25 6; RRF ook 9,
  maar met lagere rangen voor de rest). Zonder embedder is score = woorden.
  """

  alias OptimalEngine.Memory.Versioned.Embeddings, as: MemoryEmbeddings
  alias OptimalEngine.MemoryCore.FactVectors
  alias OptimalEngine.Store

  @default_limit 10
  @max_limit 50

  # Nederlands en Engels; een lidwoord of voorzetsel zegt niets over het feit.
  @stopwords MapSet.new(~w(
    de het een en of in op aan van voor met bij naar om tot uit over door als dan dat die dit
    deze er is zijn was waren wordt worden kan kunnen mag mogen moet moeten wil willen ik je jij
    u we wij jullie mijn onze ons hun hij zij ze wat hoe wie waar wanneer welke niet geen ook nog
    wel al maar te the a an and or of to on at for with are be can you
  ))

  @double_consonants ~w(bb dd ff gg kk ll mm nn pp rr ss tt)

  @type result :: %{id: String.t(), fact_text: String.t(), tak: String.t() | nil, score: float()}

  @doc """
  Zoek in de geldende feiten van `workspace_id`.

  Opties: `:tenant_id` (default "default"), `:limit` (default 10, max 50).
  Geeft `{:ok, %{mode: "hybrid" | "fts", results: [result]}}`.
  """
  @spec search(String.t(), String.t(), keyword()) ::
          {:ok, %{mode: String.t(), results: [result]}} | {:error, :empty_query | term()}
  def search(workspace_id, query, opts \\ []) when is_binary(workspace_id) do
    query = if is_binary(query), do: String.trim(query), else: ""
    limit = opts |> Keyword.get(:limit, @default_limit) |> clamp_limit()

    if query == "", do: {:error, :empty_query}, else: rank(workspace_id, query, limit, opts)
  end

  defp rank(workspace_id, query, limit, opts) do
    with {:ok, facts} <- current_facts(workspace_id, opts) do
      {mode, vector_scores} = vector_leg(query, facts)
      lexical_scores = lexical_leg(query, facts)
      weight = if mode == "hybrid", do: vector_weight(), else: 0.0

      results =
        facts
        |> Enum.map(fn fact ->
          score =
            weight * Map.get(vector_scores, fact.id, 0.0) +
              (1.0 - weight) * Map.get(lexical_scores, fact.id, 0.0)

          {fact, score}
        end)
        |> Enum.filter(fn {_fact, score} -> score > 0.0 end)
        |> Enum.sort_by(fn {fact, score} -> {-score, fact.id} end)
        |> Enum.take(limit)
        |> Enum.map(fn {fact, score} ->
          %{id: fact.id, fact_text: fact.fact_text, tak: fact.tak, score: Float.round(score, 4)}
        end)

      {:ok, %{mode: mode, results: results}}
    end
  end

  @doc """
  Herindexeer een werkruimte: de vector van elk geldend feit opnieuw, en de
  memory-projectie via `Memory.Versioned.Embeddings.rebuild/2`.
  """
  @spec reindex(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def reindex(workspace_id, opts \\ []) when is_binary(workspace_id) do
    tenant_id = Keyword.get(opts, :tenant_id, "default")

    with {:ok, facts} <- current_facts(workspace_id, tenant_id: tenant_id),
         counts = FactVectors.index(facts, force: true),
         {:ok, memories} <- MemoryEmbeddings.rebuild(workspace_id, tenant_id: tenant_id) do
      {:ok,
       %{
         workspace_id: workspace_id,
         facts:
           counts
           |> Map.delete(:skipped)
           |> Map.merge(%{total: length(facts), model: FactVectors.model()}),
         memories: memories
       }}
    end
  end

  @doc "De geldende, gekeurde, niet-verlopen feiten van een werkruimte."
  @spec current_facts(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def current_facts(workspace_id, opts \\ []) do
    sql = """
    SELECT id, fact_text, metadata
    FROM facts
    WHERE tenant_id = ?1
      AND workspace_id = ?2
      AND lifecycle_state = 'accepted'
      AND transaction_time_end IS NULL
      AND (stale_after IS NULL OR datetime(stale_after) >= datetime('now'))
    ORDER BY id
    """

    with {:ok, rows} <-
           Store.raw_query(sql, [Keyword.get(opts, :tenant_id, "default"), workspace_id]) do
      {:ok,
       Enum.map(rows, fn [id, text, metadata] ->
         %{id: id, fact_text: text || "", tak: tak(metadata)}
       end)}
    end
  end

  defp tak(metadata) when is_binary(metadata) do
    case Jason.decode(metadata) do
      {:ok, %{"tak" => tak}} when is_binary(tak) -> tak
      _ -> nil
    end
  end

  defp tak(_metadata), do: nil

  @doc false
  # Kleine letters, zonder accenten, zonder stopwoorden, met een lichte
  # Nederlandse stam (honden → hond, hapjes → hap, katten → kat).
  def tokens(text) do
    text
    |> String.downcase()
    |> :unicode.characters_to_nfd_binary()
    |> String.replace(~r/\p{Mn}/u, "")
    |> then(&Regex.scan(~r/[a-z0-9]+/, &1))
    |> List.flatten()
    |> Enum.reject(&(String.length(&1) < 2 or MapSet.member?(@stopwords, &1)))
    |> Enum.map(&stem/1)
  end

  # ── vectorpoot ───────────────────────────────────────────────────────────

  defp vector_leg(query, facts) do
    case FactVectors.embed_query(query, query_timeout_ms()) do
      {:ok, query_vector} ->
        # Nieuwe feiten zonder vector: een handvol meteen, de rest op de
        # achtergrond. Tot dan tellen ze alleen met hun woorden.
        FactVectors.index(facts, max: inline_index_max(), timeout_ms: query_timeout_ms())

        similarities =
          Enum.flat_map(facts, fn fact ->
            case FactVectors.get(fact.id) do
              nil -> []
              vector -> [{fact.id, FactVectors.dot(query_vector, vector)}]
            end
          end)

        {"hybrid", min_max(similarities)}

      :error ->
        {"fts", %{}}
    end
  end

  defp min_max([]), do: %{}

  defp min_max(pairs) do
    {low, high} = pairs |> Enum.map(&elem(&1, 1)) |> Enum.min_max()
    span = high - low

    Map.new(pairs, fn {id, value} ->
      {id, if(span > 0.0, do: (value - low) / span, else: 1.0)}
    end)
  end

  # ── woordpoot (BM25, k1 1,2 · b 0,75) ────────────────────────────────────

  defp lexical_leg(query, facts) do
    terms = query |> tokens() |> Enum.uniq()
    docs = Enum.map(facts, fn fact -> {fact.id, tokens(fact.fact_text)} end)
    n = length(docs)

    if terms == [] or n == 0 do
      %{}
    else
      avgdl = max(Enum.sum(Enum.map(docs, fn {_id, t} -> length(t) end)) / n, 1.0)

      df =
        Map.new(terms, fn term ->
          {term, Enum.count(docs, fn {_id, t} -> term in t end)}
        end)

      scores =
        docs
        |> Enum.map(fn {id, doc_terms} -> {id, bm25(terms, doc_terms, df, n, avgdl)} end)
        |> Enum.filter(fn {_id, score} -> score > 0.0 end)

      case scores do
        [] ->
          %{}

        _ ->
          top = scores |> Enum.map(&elem(&1, 1)) |> Enum.max()
          Map.new(scores, fn {id, score} -> {id, score / top} end)
      end
    end
  end

  defp bm25(terms, doc_terms, df, n, avgdl) do
    frequencies = Enum.frequencies(doc_terms)
    length_norm = 1.0 - 0.75 + 0.75 * length(doc_terms) / avgdl

    Enum.reduce(terms, 0.0, fn term, acc ->
      case Map.get(frequencies, term, 0) do
        0 ->
          acc

        tf ->
          idf = :math.log(1.0 + (n - df[term] + 0.5) / (df[term] + 0.5))
          acc + idf * tf * 2.2 / (tf + 1.2 * length_norm)
      end
    end)
  end

  defp stem(word) do
    word
    |> strip_suffix("s", 5, &(not String.ends_with?(&1, "ss")))
    |> strip_diminutive()
    |> strip_plural_en()
  end

  defp strip_suffix(word, suffix, min_length, guard) do
    if String.length(word) >= min_length and String.ends_with?(word, suffix) and guard.(word),
      do: String.slice(word, 0, String.length(word) - String.length(suffix)),
      else: word
  end

  defp strip_diminutive(word) do
    cond do
      String.length(word) >= 6 and String.ends_with?(word, "tje") -> String.slice(word, 0..-4//1)
      String.length(word) >= 5 and String.ends_with?(word, "je") -> String.slice(word, 0..-3//1)
      true -> word
    end
  end

  defp strip_plural_en(word) do
    if String.length(word) >= 5 and String.ends_with?(word, "en") do
      stem = String.slice(word, 0..-3//1)

      if String.slice(stem, -2..-1//1) in @double_consonants,
        do: String.slice(stem, 0..-2//1),
        else: stem
    else
      word
    end
  end

  # ── config ───────────────────────────────────────────────────────────────

  defp config, do: Application.get_env(:optimal_engine, :fact_search, [])
  defp vector_weight, do: Keyword.get(config(), :vector_weight, 0.7)
  defp query_timeout_ms, do: Keyword.get(config(), :query_timeout_ms, 3_000)
  defp inline_index_max, do: Keyword.get(config(), :inline_index_max, 16)

  defp clamp_limit(limit) when is_integer(limit) and limit > 0, do: min(limit, @max_limit)
  defp clamp_limit(_limit), do: @default_limit
end

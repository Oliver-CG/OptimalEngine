defmodule OptimalEngine.MemoryCore.FactVectors do
  @moduledoc """
  De vectoren van de geldende feiten: een herbouwbare projectie in ETS.

  Waarom geen tabel: vectoren, chunks en FTS-rijen zijn in deze engine
  herbouwbare projecties, en een feit verandert nooit van tekst (een herziening
  of samenvoeging maakt een nieuw id). Een feit-id plus model is dus een
  stabiele sleutel, en de projectie is na een herstart in seconden terug: bij
  het opstarten en daarna periodiek indexeert dit proces elk geldend feit dat
  nog geen vector heeft. Zo komt er geen schemawijziging bij.

  De embedder is `nomic-embed-text` via Ollama, met de taakvoorvoegsels die dat
  model verwacht (`search_document: ` voor een feit, `search_query: ` voor een
  vraag). Elke vector wordt genormaliseerd opgeslagen, zodat cosinus een
  inproduct is.

  ## Config

      config :optimal_engine, :fact_search,
        model: "nomic-embed-text",          # default: de :ollama embed_model
        embedder: fn text -> {:ok, [float]} | {:error, term} end,
        warm: true,                          # indexeer bij opstart en periodiek
        warm_delay_ms: 5_000,
        warm_interval_ms: 600_000
  """

  use GenServer

  require Logger

  alias OptimalEngine.Embed.Ollama

  @table :oe_fact_vectors
  @task_supervisor OptimalEngine.Memory.EmbeddingTaskSupervisor

  # ── publieke API ─────────────────────────────────────────────────────────

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Het embedmodel waaronder de vectoren staan."
  @spec model() :: String.t()
  def model do
    config()[:model] ||
      Application.get_env(:optimal_engine, :ollama, [])[:embed_model] ||
      "nomic-embed-text"
  end

  @doc "De ingestelde embedder: `text -> {:ok, [float]} | {:error, term}`."
  @spec embedder() :: (String.t() -> {:ok, [float()]} | {:error, term()})
  def embedder do
    case config()[:embedder] do
      fun when is_function(fun, 1) -> fun
      _ -> fn text -> Ollama.embed(text, model: model()) end
    end
  end

  @doc """
  Embed een zoekvraag, begrensd in tijd. Een fout, crash of hang van de
  embedder geeft `:error`; de aanroeper valt dan terug op woorden.
  """
  @spec embed_query(String.t(), non_neg_integer()) :: {:ok, binary()} | :error
  def embed_query(query, timeout_ms) do
    case run_bounded(fn -> call_embedder("search_query: " <> query) end, timeout_ms) do
      {:ok, vector} -> {:ok, vector}
      _ -> :error
    end
  end

  @doc "De opgeslagen vector van een feit, of nil."
  @spec get(String.t()) :: binary() | nil
  def get(fact_id) do
    case :ets.lookup(@table, {model(), fact_id}) do
      [{_key, vector}] -> vector
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @doc "Aantal feiten met een vector onder het huidige model."
  @spec count() :: non_neg_integer()
  def count do
    m = model()
    :ets.select_count(@table, [{{{m, :_}, :_}, [], [true]}])
  rescue
    ArgumentError -> 0
  end

  @doc """
  Indexeer feiten (`%{id, fact_text}`). Zonder `force: true` alleen de feiten
  die nog geen vector hebben. `max: n` indexeert er hoogstens n en laat de rest
  aan de achtergrond (`index_later/1`).
  """
  @spec index([map()], keyword()) :: %{
          indexed: non_neg_integer(),
          failed: non_neg_integer(),
          skipped: non_neg_integer()
        }
  def index(facts, opts \\ []) do
    force = Keyword.get(opts, :force, false)
    todo = if force, do: facts, else: Enum.reject(facts, &get(&1.id))
    skipped = length(facts) - length(todo)

    {now, later} =
      case Keyword.get(opts, :max) do
        nil -> {todo, []}
        max -> Enum.split(todo, max)
      end

    if later != [], do: index_later(later)

    counts =
      @task_supervisor
      |> Task.Supervisor.async_stream_nolink(
        now,
        fn fact -> {fact.id, call_embedder("search_document: " <> fact.fact_text)} end,
        max_concurrency: Keyword.get(opts, :concurrency, 4),
        timeout: Keyword.get(opts, :timeout_ms, 30_000),
        on_timeout: :kill_task,
        ordered: false
      )
      |> Enum.reduce(%{indexed: 0, failed: 0}, fn
        {:ok, {id, {:ok, vector}}}, acc ->
          :ets.insert(@table, {{model(), id}, vector})
          Map.update!(acc, :indexed, &(&1 + 1))

        _other, acc ->
          Map.update!(acc, :failed, &(&1 + 1))
      end)

    Map.put(counts, :skipped, skipped)
  end

  @doc "Laat feiten op de achtergrond indexeren; blokkeert niet."
  @spec index_later([map()]) :: :ok
  def index_later(facts) do
    GenServer.cast(__MODULE__, {:index, Enum.map(facts, &Map.take(&1, [:id, :fact_text]))})
  end

  @doc "Inproduct van twee genormaliseerde vectoren (float32, little-endian)."
  @spec dot(binary(), binary()) :: float()
  def dot(left, right), do: dot(left, right, 0.0)

  defp dot(<<a::float-little-32, left::binary>>, <<b::float-little-32, right::binary>>, acc),
    do: dot(left, right, acc + a * b)

  defp dot(_left, _right, acc), do: acc

  # ── GenServer ────────────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])

    if Keyword.get(config(), :warm, true) do
      Process.send_after(self(), :warm, Keyword.get(config(), :warm_delay_ms, 5_000))
    end

    {:ok, %{}}
  end

  @impl true
  def handle_cast({:index, facts}, state) do
    index(facts)
    {:noreply, state}
  end

  @impl true
  def handle_info(:warm, state) do
    warm()

    case Keyword.get(config(), :warm_interval_ms, 600_000) do
      interval when is_integer(interval) and interval > 0 ->
        Process.send_after(self(), :warm, interval)

      _ ->
        :ok
    end

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # Elk geldend feit in elke werkruimte dat nog geen vector heeft; de vector van
  # een feit dat niet meer geldt (vervangen, ingetrokken) gaat eruit.
  defp warm do
    sql = """
    SELECT id, fact_text FROM facts
    WHERE lifecycle_state = 'accepted' AND transaction_time_end IS NULL
    """

    with {:ok, rows} <- OptimalEngine.Store.raw_query(sql, []),
         facts = Enum.map(rows, fn [id, text] -> %{id: id, fact_text: text || ""} end),
         _ = prune(MapSet.new(facts, & &1.id)),
         missing when missing != [] <- Enum.reject(facts, &get(&1.id)),
         # Eén proef vóór de rest: is de embedder weg, dan één regel in het log
         # in plaats van een mislukte aanroep per feit, elke ronde opnieuw.
         {:ok, _probe} <- run_bounded(fn -> call_embedder("search_document: probe") end, 5_000) do
      counts = index(missing)
      Logger.info("[FactVectors] warm: #{inspect(counts)} (#{count()} feiten met vector)")
    else
      [] -> :ok
      {:error, reason} -> Logger.warning("[FactVectors] warm overgeslagen: #{inspect(reason)}")
      :error -> Logger.warning("[FactVectors] warm overgeslagen: embedder antwoordt niet")
      other -> Logger.warning("[FactVectors] warm: #{inspect(other)}")
    end
  rescue
    exception -> Logger.warning("[FactVectors] warm faalde: #{Exception.message(exception)}")
  end

  # ── intern ───────────────────────────────────────────────────────────────

  defp prune(current_ids) do
    @table
    |> :ets.select([{{:"$1", :_}, [], [:"$1"]}])
    |> Enum.reject(fn {_model, id} -> MapSet.member?(current_ids, id) end)
    |> Enum.each(&:ets.delete(@table, &1))
  end

  defp config, do: Application.get_env(:optimal_engine, :fact_search, [])

  # De embedder in een eigen, niet-gelinkt proces: een crash of hang raakt de
  # aanroeper niet.
  defp run_bounded(fun, timeout_ms) do
    task = Task.Supervisor.async_nolink(@task_supervisor, fun)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      _ -> :error
    end
  end

  defp call_embedder(text) do
    case embedder().(text) do
      {:ok, vector} when is_list(vector) and vector != [] -> normalize(vector)
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_embedding}
    end
  end

  defp normalize(vector) do
    norm = :math.sqrt(Enum.reduce(vector, 0.0, fn x, acc -> acc + x * x end))

    if norm == 0.0 do
      {:error, :zero_vector}
    else
      {:ok, for(x <- vector, into: <<>>, do: <<x / norm::float-little-32>>)}
    end
  end
end

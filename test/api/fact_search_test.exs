defmodule OptimalEngine.API.FactSearchTest.Nep do
  @moduledoc false
  # Een nep-embedder met begrippen in plaats van woorden: woorden die hetzelfde
  # betekenen landen op dezelfde as, dus een parafrase lijkt op het origineel
  # terwijl ze geen woord delen. Zo meet de toets de vectorpoot en niet de
  # woordpoot; de echte kwaliteit (nomic-embed-text op de echte feiten) is een
  # aparte meting buiten de suite.
  @assen %{
    "high" => 0,
    "tea" => 0,
    "theearrangement" => 0,
    "dinsdag" => 1,
    "werkdagen" => 1,
    "november" => 2,
    "oktober" => 2,
    "mei" => 2,
    "glazenwasser" => 3,
    "keuken" => 4,
    "verbouwing" => 4,
    "honden" => 5
  }
  @dims 8

  def embed(text) do
    raak =
      text
      |> String.downcase()
      |> String.split(~r/[^\p{L}]+/u, trim: true)
      |> Enum.map(&Map.get(@assen, &1))
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    # De laatste as is een kleine constante, zodat geen vector nul is.
    {:ok,
     for(
       i <- 0..(@dims - 1),
       do: if(i in raak, do: 1.0, else: if(i == @dims - 1, do: 0.1, else: 0.0))
     )}
  end

  def weg(_text), do: {:error, :ollama_unavailable}
  def ontploft(_text), do: raise("embedder stuk")

  def hangt(_text) do
    Process.sleep(5_000)
    {:ok, [1.0]}
  end
end

defmodule OptimalEngine.API.FactSearchTest do
  @moduledoc """
  POST /api/memory-core/facts/search — zoeken in de gekeurde, geldende feiten,
  op betekenis én op woorden. POST /api/memory-core/reindex — de vectoren van
  alle geldende feiten en memories van een werkruimte opnieuw.

  Waarom (gemeten 27-09): het brein zocht niet op betekenis. De embedder was
  onbereikbaar (40 van 1104 memories met een vector) en search/rag zochten in
  memories en claimbronnen, niet in de feiten die Nikki keurt. De vraag "kan ik
  een high tea doen op een dinsdag in november" vond daardoor het feit niet.

  Wat deze toetsen vastleggen:
  · een parafrase vindt het geplante feit, ook zonder één gedeeld woord;
  · het antwoord draagt feit-id, tekst, tak en score;
  · alleen geldende gekeurde feiten: ingetrokken, vervangen, verlopen of
    ongekeurde feiten en verworpen claims komen niet terug, en een andere
    werkruimte evenmin;
  · de zoekvraag wordt nergens weggeschreven;
  · embedder weg (fout, crash of hang): terugval op woorden, geen crash;
  · herindexeren bouwt de vectoren van alle geldende feiten opnieuw.
  """
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias OptimalEngine.API.FactSearchTest.Nep
  alias OptimalEngine.API.Router
  alias OptimalEngine.MemoryCore.{Fact, FactVectors, Store}

  @opts Router.init([])
  @vraag "kan ik een high tea doen op een dinsdag in november"

  setup do
    OptimalEngine.API.RateLimiter.reset()
    vorige = Application.get_env(:optimal_engine, :fact_search)

    zet_embedder(&Nep.embed/1)

    on_exit(fn ->
      if vorige,
        do: Application.put_env(:optimal_engine, :fact_search, vorige),
        else: Application.delete_env(:optimal_engine, :fact_search)
    end)

    :ok
  end

  defp zet_embedder(embedder) do
    huidig = Application.get_env(:optimal_engine, :fact_search, [])

    Application.put_env(
      :optimal_engine,
      :fact_search,
      huidig
      |> Keyword.put(:embedder, embedder)
      |> Keyword.put(:query_timeout_ms, 300)
      |> Keyword.put(:warm_interval_ms, 0)
    )
  end

  # Elk verzoek draagt een eigen sleutel: de rate limiter emmert anoniem per
  # IP en die emmer deelt de hele suite (zie claim_retraction_test.exs).
  defp principal_token(principal_id) do
    {:ok, _} =
      OptimalEngine.Identity.Principal.upsert(%{
        id: principal_id,
        kind: :user,
        display_name: principal_id
      })

    {:ok, %{key: token}} =
      OptimalEngine.Auth.ApiKey.mint(%{
        tenant_id: "default",
        name: "zoek-test-#{System.unique_integer([:positive])}",
        principal_id: principal_id
      })

    token
  end

  defp sleutel do
    case Process.get(:zoek_sleutel) do
      nil ->
        token = principal_token("user:zoeker-#{System.unique_integer([:positive])}")
        Process.put(:zoek_sleutel, token)
        token

      token ->
        token
    end
  end

  defp request(method, path, body \\ nil) do
    case body do
      nil ->
        conn(method, path)

      b ->
        conn(method, path, Jason.encode!(b)) |> put_req_header("content-type", "application/json")
    end
    |> put_req_header("x-api-key", sleutel())
    |> Router.call(@opts)
  end

  defp zoek(ws, q, extra \\ %{}) do
    conn =
      request(
        :post,
        "/api/memory-core/facts/search",
        Map.merge(%{"workspace" => ws, "q" => q}, extra)
      )

    assert conn.status == 200, "zoeken gaf #{conn.status}: #{conn.resp_body}"
    Jason.decode!(conn.resp_body)
  end

  defp ids(body), do: Enum.map(body["results"], & &1["id"])

  defp werkruimte, do: "zoek-#{System.unique_integer([:positive])}"

  # Een geldend, gekeurd feit, rechtstreeks in de feitentabel.
  defp plant(ws, tekst, extra \\ %{}) do
    id = "fact_toets_#{System.unique_integer([:positive])}"

    attrs =
      Map.merge(
        %{
          id: id,
          tenant_id: "default",
          workspace_id: ws,
          fact_text: tekst,
          lifecycle_state: "accepted",
          verification_status: "reviewed",
          metadata: %{"tak" => "zaak"}
        },
        extra
      )

    :ok = Store.insert_fact(Fact.new(attrs))
    id
  end

  defp parafrase_zaak(ws) do
    %{
      doel:
        plant(
          ws,
          "Het theearrangement serveren we alleen op werkdagen, van oktober tot en met mei."
        ),
      glazenwasser:
        plant(ws, "De glazenwasser komt op dinsdag.", %{metadata: %{"tak" => "buiten"}}),
      keuken: plant(ws, "In november is de keuken dicht voor verbouwing."),
      honden: plant(ws, "Honden zijn welkom.", %{metadata: %{"tak" => "regels"}})
    }
  end

  describe "POST /api/memory-core/facts/search" do
    test "een parafrase vindt het geplante feit, ook zonder één gedeeld woord" do
      ws = werkruimte()
      feiten = parafrase_zaak(ws)

      body = zoek(ws, @vraag)

      assert body["mode"] == "hybrid"
      assert hd(ids(body)) == feiten.doel
    end

    test "het antwoord draagt feit-id, tekst, tak en score" do
      ws = werkruimte()
      feiten = parafrase_zaak(ws)

      body = zoek(ws, "komt de glazenwasser op dinsdag")
      [eerste | _] = body["results"]

      assert eerste["id"] == feiten.glazenwasser
      assert eerste["fact_text"] == "De glazenwasser komt op dinsdag."
      assert eerste["tak"] == "buiten"
      assert is_float(eerste["score"]) and eerste["score"] > 0
      assert Map.keys(eerste) |> Enum.sort() == ["fact_text", "id", "score", "tak"]
    end

    test "limit begrenst het aantal treffers" do
      ws = werkruimte()
      parafrase_zaak(ws)

      assert length(zoek(ws, @vraag, %{"limit" => 2})["results"]) == 2
    end

    test "zonder vraag: 400" do
      conn =
        request(:post, "/api/memory-core/facts/search", %{"workspace" => werkruimte(), "q" => "  "})

      assert conn.status == 400
    end

    test "alleen geldende gekeurde feiten: ingetrokken, vervangen, verlopen, ongekeurd en verworpen komen niet terug" do
      ws = werkruimte()
      keurder = principal_token("user:keurder-#{System.unique_integer([:positive])}")

      geldend = plant(ws, "De high tea kost 36,50 euro per persoon.")

      ongekeurd =
        plant(ws, "De high tea kost 12 euro per persoon.", %{lifecycle_state: "candidate"})

      anders = plant("#{ws}-anders", "De high tea kost 50 euro per persoon.")

      # Ingetrokken, langs de echte weg: memory, claim, promotie, intrekking.
      te_trekken = gepromoveerd(ws, "De high tea kost 41,50 euro per persoon.", keurder)

      assert te_trekken in ids(zoek(ws, "wat kost de high tea")),
             "vóór de intrekking moet de toets het feit zien"

      claim_id = claim_van(ws, te_trekken)

      trek =
        signed(
          :post,
          "/api/memory-core/claims/#{claim_id}/retract",
          %{"workspace" => ws, "reason" => "prijs klopte niet"},
          keurder
        )

      assert trek.status == 200

      # Vervangen, langs de echte weg: een herziening sluit het oude feit.
      oud = gepromoveerd(ws, "De high tea kost 38 euro per persoon.", keurder)

      herzien =
        signed(
          :patch,
          "/api/memory-core/facts/#{oud}?workspace=#{ws}",
          %{"fact_text" => "De high tea kost 36 euro per persoon.", "reason" => "nieuwe prijs"},
          keurder
        )

      assert herzien.status == 200
      nieuw = Jason.decode!(herzien.resp_body)["fact"]["id"]

      # Verlopen: stale_after ligt in het verleden.
      verlopen =
        plant(ws, "De high tea kost 30 euro per persoon.", %{stale_after: "2020-01-01T00:00:00Z"})

      # Verworpen: een claim die de keurder afwijst wordt nooit een feit.
      verworpen_tekst = "De high tea kost 99 euro per persoon."
      create = request(:post, "/api/memory", %{"workspace" => ws, "content" => verworpen_tekst})
      assert create.status == 201
      verworpen_claim = claim_met_tekst(ws, verworpen_tekst)

      afwijzing =
        signed(
          :post,
          "/api/memory-core/claims/#{verworpen_claim}/reject",
          %{"workspace" => ws, "reason" => "verzonnen"},
          keurder
        )

      assert afwijzing.status == 200

      gevonden = ids(zoek(ws, "wat kost de high tea", %{"limit" => 50}))

      assert geldend in gevonden
      assert nieuw in gevonden
      refute te_trekken in gevonden
      refute oud in gevonden
      refute verlopen in gevonden
      refute ongekeurd in gevonden
      refute anders in gevonden

      teksten =
        zoek(ws, "wat kost de high tea", %{"limit" => 50})["results"] |> Enum.map(& &1["fact_text"])

      refute verworpen_tekst in teksten
    end

    test "de zoekvraag staat na afloop nergens in de database" do
      ws = werkruimte()
      parafrase_zaak(ws)
      merk = "zoekmerk#{System.unique_integer([:positive])}"

      # Positieve controle: de scan vindt een merk dat wél geschreven wordt.
      # Zonder deze regel kan een kapotte scan de toets groen maken.
      controle = "controlemerk#{System.unique_integer([:positive])}"

      assert request(:post, "/api/memory", %{"workspace" => ws, "content" => "notitie #{controle}"}).status ==
               201

      assert ergens_in_db?(controle), "de scan vindt een geschreven merk niet — hij meet niets"

      zoek(ws, "kan ik een high tea doen op #{merk} in november")
      zoek(ws, "#{merk}")

      refute ergens_in_db?(merk), "de zoekvraag is weggeschreven"
    end

    test "embedder geeft een fout: terugval op woorden, geen crash" do
      ws = werkruimte()
      feiten = parafrase_zaak(ws)
      zet_embedder(&Nep.weg/1)

      body = zoek(ws, @vraag)

      assert body["mode"] == "fts"
      gevonden = ids(body)
      assert feiten.glazenwasser in gevonden
      assert feiten.keuken in gevonden
      # Zonder betekenis vindt alleen de woordpoot iets: de parafrase niet.
      refute feiten.doel in gevonden
    end

    test "embedder crasht: terugval op woorden, geen crash" do
      ws = werkruimte()
      feiten = parafrase_zaak(ws)
      zet_embedder(&Nep.ontploft/1)

      body = zoek(ws, @vraag)

      assert body["mode"] == "fts"
      assert feiten.glazenwasser in ids(body)
    end

    test "embedder hangt: terugval binnen de tijdgrens, geen crash" do
      ws = werkruimte()
      feiten = parafrase_zaak(ws)
      zet_embedder(&Nep.hangt/1)

      {micro, body} = :timer.tc(fn -> zoek(ws, @vraag) end)

      assert body["mode"] == "fts"
      assert feiten.glazenwasser in ids(body)

      assert micro < 3_000_000,
             "de zoekvraag wachtte #{div(micro, 1000)} ms op een hangende embedder"
    end
  end

  describe "POST /api/memory-core/reindex" do
    test "bouwt de vectoren van alle geldende feiten en de memories van de werkruimte opnieuw" do
      ws = werkruimte()
      parafrase_zaak(ws)

      plant(ws, "Een vervangen feit.", %{
        lifecycle_state: "superseded",
        transaction_time_end: "2026-09-01T00:00:00Z"
      })

      assert request(:post, "/api/memory", %{
               "workspace" => ws,
               "content" => "Een memory om te indexeren."
             }).status == 201

      conn = request(:post, "/api/memory-core/reindex", %{"workspace" => ws})

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["workspace_id"] == ws
      assert body["facts"]["total"] == 4
      assert body["facts"]["indexed"] == 4
      assert body["facts"]["failed"] == 0
      assert body["memories"]["total"] == 1
    end

    test "embedder weg: telt de mislukte feiten, geen crash" do
      ws = werkruimte()
      parafrase_zaak(ws)
      zet_embedder(&Nep.weg/1)

      conn = request(:post, "/api/memory-core/reindex", %{"workspace" => ws})

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["facts"]["indexed"] == 0
      assert body["facts"]["failed"] == 4
    end
  end

  describe "FactVectors bij opstart en periodiek" do
    # Gemeten 27-09: een weggevallen embedder gaf 11.995 mislukte aanroepen in
    # 72 uur. Een warmronde mag daar niet één per feit aan toevoegen.
    test "embedder weg: één proef in plaats van een aanroep per feit; terug: elk feit krijgt zijn vector" do
      ws = werkruimte()
      feiten = parafrase_zaak(ws)
      toets = self()

      zet_embedder(fn tekst ->
        send(toets, {:embed, tekst})
        {:error, :ollama_unavailable}
      end)

      send(FactVectors, :warm)
      :sys.get_state(FactVectors)
      aanroepen = tel_berichten(0)

      assert aanroepen == 1,
             "de warmronde deed #{aanroepen} aanroepen tegen een weggevallen embedder"

      zet_embedder(&Nep.embed/1)
      send(FactVectors, :warm)
      :sys.get_state(FactVectors)

      for id <- Map.values(feiten), do: assert(FactVectors.get(id), "#{id} kreeg geen vector")
    end
  end

  defp tel_berichten(n) do
    receive do
      {:embed, _tekst} -> tel_berichten(n + 1)
    after
      0 -> n
    end
  end

  # ── helpers langs de echte weg ─────────────────────────────────────────────

  defp signed(method, path, body, token) do
    conn(method, path, Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-api-key", token)
    |> Router.call(@opts)
  end

  defp claim_met_tekst(ws, tekst) do
    conn = request(:get, "/api/memory-core/claims?workspace=#{ws}")
    %{"claims" => claims} = Jason.decode!(conn.resp_body)
    claim = Enum.find(claims, &(&1["claim_text"] =~ tekst))
    assert claim, "geen claim voor #{tekst}"
    claim["id"]
  end

  defp gepromoveerd(ws, fact_text, keurder) do
    inhoud = "Kladzin #{System.unique_integer([:positive])}"
    assert request(:post, "/api/memory", %{"workspace" => ws, "content" => inhoud}).status == 201
    claim_id = claim_met_tekst(ws, inhoud)

    promote =
      signed(
        :post,
        "/api/memory-core/claims/#{claim_id}/promote",
        %{"workspace" => ws, "fact_text" => fact_text},
        keurder
      )

    assert promote.status == 200
    Jason.decode!(promote.resp_body)["fact"]["id"]
  end

  defp claim_van(ws, fact_id) do
    {:ok, fact} = Store.get_fact(ws, fact_id)
    hd(fact.accepted_claim_ids)
  end

  # Elke tekst- en blobwaarde in elke tabel, virtuele FTS-tabellen incluis.
  defp ergens_in_db?(merk) do
    {:ok, tabellen} =
      OptimalEngine.Store.raw_query(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'",
        []
      )

    Enum.any?(tabellen, fn [tabel] ->
      case OptimalEngine.Store.raw_query(~s(SELECT * FROM "#{tabel}"), []) do
        {:ok, rijen} -> Enum.any?(rijen, fn rij -> Enum.any?(rij, &bevat?(&1, merk)) end)
        _ -> false
      end
    end)
  end

  defp bevat?(waarde, merk) when is_binary(waarde), do: String.contains?(waarde, merk)
  defp bevat?(_waarde, _merk), do: false
end

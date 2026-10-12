defmodule OptimalEngine.API.SleutelgrensTest do
  @moduledoc """
  L1.9, de sleutelgrens: wat het systeem uit het brein haalt, is alleen wat het
  huis heeft gekeurd; een open, afgewezen of ingetrokken claim komt er met een
  agentsleutel niet uit.

  Het lek dat dit dicht (gemeten 09-10, STAND Ruiterhuys): open claims kwamen
  terug via `/api/search` en `/api/grep`, de zoekpaden over memories en chunks
  die de oude bibliothecaris via de engine-MCP gebruikt. Een claim wordt
  geplaatst als memory (`POST /api/memory`), dus elke route die memories,
  chunks of bronnen leest, draagt de ongekeurde tekst.

  Drie soorten sleutel, naar hun scopes:
  · beheersleutel (`admin` of `*`): alles, op de box;
  · werksleutel (`write`, geen beheer): plaatsen, keuren en de keurlijst;
    de ruwe zoekpaden niet;
  · agentsleutel (al het andere, zoals de leessleutels van `mint_read_keys`):
    alleen gekeurde, geldende feiten.

  Positieve controle (regel 34): met de beheersleutel staan de geplante woorden
  wél in de memories en de keurlijst, dus een leeg antwoord met een andere
  sleutel is de grens en geen toets die niets kan vinden.
  """
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias OptimalEngine.API.Router

  @opts Router.init([])

  setup do
    OptimalEngine.API.RateLimiter.reset()

    ws = "sleutelgrens-#{System.unique_integer([:positive])}"

    sleutels = %{
      beheer: sleutel(["admin"], nil),
      werk: sleutel(["read", "write"], "system:intake-#{uniek()}"),
      keur: sleutel(["read", "write"], "user:keurder-#{uniek()}"),
      lees: sleutel(["read"], nil)
    }

    woorden = %{
      open: "open" <> uniek(),
      afgewezen: "afgewezen" <> uniek(),
      ingetrokken: "ingetrokken" <> uniek(),
      gekeurd: "gekeurd" <> uniek()
    }

    {open_claim, open_memory} = plaats(ws, woorden.open, sleutels.werk)

    {afgewezen_claim, _} = plaats(ws, woorden.afgewezen, sleutels.werk)

    assert vraag(:post, "/api/memory-core/claims/#{afgewezen_claim["id"]}/reject", sleutels.keur, %{
             "workspace" => ws,
             "reason" => "klopt niet"
           }).status == 200

    {ingetrokken_claim, _} = plaats(ws, woorden.ingetrokken, sleutels.werk)
    keur(ws, ingetrokken_claim, woorden.ingetrokken, sleutels.keur)

    assert vraag(
             :post,
             "/api/memory-core/claims/#{ingetrokken_claim["id"]}/retract",
             sleutels.keur,
             %{
               "workspace" => ws,
               "reason" => "niet meer waar"
             }
           ).status == 200

    {gekeurd_claim, _} = plaats(ws, woorden.gekeurd, sleutels.werk)
    keur(ws, gekeurd_claim, woorden.gekeurd, sleutels.keur)

    {:ok,
     ws: ws,
     sleutels: sleutels,
     woorden: woorden,
     open_claim: open_claim,
     afgewezen_claim: afgewezen_claim,
     open_memory: open_memory}
  end

  # ── hulp ──────────────────────────────────────────────────────────────────

  defp uniek do
    for _ <- 1..10, into: "", do: <<Enum.random(?a..?z)>>
  end

  defp sleutel(scopes, principal_id) do
    if principal_id do
      {:ok, _} =
        OptimalEngine.Identity.Principal.upsert(%{
          id: principal_id,
          kind: if(String.starts_with?(principal_id, "user:"), do: :user, else: :service),
          display_name: principal_id
        })
    end

    {:ok, %{key: token}} =
      OptimalEngine.Auth.ApiKey.mint(%{
        tenant_id: "default",
        name: "sleutelgrens-#{System.unique_integer([:positive])}",
        principal_id: principal_id,
        scopes: scopes
      })

    token
  end

  defp vraag(method, path, token, body \\ nil) do
    case body do
      nil ->
        conn(method, path)

      b ->
        conn(method, path, Jason.encode!(b)) |> put_req_header("content-type", "application/json")
    end
    |> put_req_header("x-api-key", token)
    |> Router.call(@opts)
  end

  defp plaats(ws, woord, token) do
    inhoud = "De serre is beschikbaar voor groepen, codewoord #{woord}"
    create = vraag(:post, "/api/memory", token, %{"workspace" => ws, "content" => inhoud})
    assert create.status == 201
    {:ok, memory} = Jason.decode(create.resp_body)

    beheer = sleutel(["admin"], nil)
    lijst = vraag(:get, "/api/memory-core/claims?workspace=#{ws}", beheer)
    {:ok, %{"claims" => claims}} = Jason.decode(lijst.resp_body)
    claim = Enum.find(claims, &String.contains?(Jason.encode!(&1), woord))
    assert claim, "de geplante claim met #{woord} staat niet in de wachtrij"
    {claim, memory}
  end

  defp keur(ws, claim, woord, token) do
    promote =
      vraag(:post, "/api/memory-core/claims/#{claim["id"]}/promote", token, %{
        "workspace" => ws,
        "fact_text" => "Gekeurd: de serre is beschikbaar voor groepen, codewoord #{woord}"
      })

    assert promote.status == 200
  end

  # Elk leespad dat een sleutel kan proberen. De lijst is breed met opzet: de
  # grens moet op élk pad houden, niet alleen op de twee waar het lek gemeten is.
  defp ruwe_paden(ctx, woord) do
    ws = ctx.ws
    memory_id = ctx.open_memory["id"]
    bron = ctx.open_claim["source_package_id"]

    [
      {:get, "/api/search?q=#{woord}&workspace=#{ws}", nil},
      {:get, "/api/search?q=#{woord}&workspace=#{ws}&type=memory", nil},
      {:get, "/api/grep?q=#{woord}&workspace=#{ws}", nil},
      {:get, "/api/grep?q=#{woord}&workspace=#{ws}&literal=true", nil},
      {:post, "/api/rag", %{"query" => woord, "workspace" => ws}},
      {:get, "/api/rag/stream?query=#{woord}&workspace=#{ws}", nil},
      {:get, "/api/memory?workspace=#{ws}", nil},
      {:get, "/api/memory?workspace=#{ws}&q=#{woord}", nil},
      {:get, "/api/memory/#{memory_id}", nil},
      {:get, "/api/memory/#{memory_id}/versions", nil},
      {:get, "/v1/memory?workspace=#{ws}", nil},
      {:get, "/api/batch/export/memories?workspace=#{ws}", nil},
      {:get, "/api/batch/export/workspace?workspace=#{ws}", nil},
      {:get, "/api/wiki?workspace=#{ws}", nil},
      {:get, "/api/l0?workspace=#{ws}", nil},
      {:get, "/api/recall/actions?workspace=#{ws}&topic=#{woord}", nil},
      {:post, "/api/assemble", %{"query" => woord, "workspace" => ws}},
      {:post, "/api/render/context", %{"query" => woord, "workspace" => ws}}
    ] ++
      if(bron, do: [{:get, "/api/memory-core/source-packages/#{bron}", nil}], else: [])
  end

  defp keur_paden(ctx, woord) do
    ws = ctx.ws

    [
      {:get, "/api/memory-core/claims?workspace=#{ws}", nil},
      {:get, "/api/memory-core/claims/#{ctx.open_claim["id"]}?workspace=#{ws}", nil},
      {:get, "/api/memory-core/claims/#{ctx.afgewezen_claim["id"]}?workspace=#{ws}", nil},
      {:get, "/api/memory-core/claim-review?workspace=#{ws}", nil},
      {:get, "/api/memory-core/claim-review?workspace=#{ws}&review_status=unreviewed", nil},
      {:get, "/api/memory-core/claim-review?workspace=#{ws}&review_status=rejected", nil},
      {:get, "/api/memory-core/facts?workspace=#{ws}", nil},
      {:get, "/api/memory-core/facts?workspace=#{ws}&lifecycle_state=retracted", nil},
      {:post, "/api/memory-core/facts/search", %{"q" => woord, "workspace" => ws}}
    ]
  end

  defp lekken(paden, token, woorden) do
    for {method, path, body} <- paden,
        conn = vraag(method, path, token, body),
        woord <- woorden,
        String.contains?(conn.resp_body || "", woord),
        do: {method, path, woord, conn.status}
  end

  # ── toetsen ───────────────────────────────────────────────────────────────

  describe "positieve controle" do
    test "met de beheersleutel staan de geplante woorden in memories en keurlijst", ctx do
      memories = vraag(:get, "/api/memory?workspace=#{ctx.ws}&limit=50", ctx.sleutels.beheer)
      assert memories.status == 200

      for woord <- Map.values(ctx.woorden) do
        assert memories.resp_body =~ woord
      end

      keurlijst =
        vraag(:get, "/api/memory-core/claim-review?workspace=#{ctx.ws}", ctx.sleutels.beheer)

      assert keurlijst.resp_body =~ ctx.woorden.open
      assert keurlijst.resp_body =~ ctx.woorden.afgewezen
    end
  end

  describe "open_claim_onvindbaar" do
    test "een agentsleutel vindt een open, afgewezen of ingetrokken claim op geen enkel pad", ctx do
      ongekeurd = [ctx.woorden.open, ctx.woorden.afgewezen, ctx.woorden.ingetrokken]

      paden =
        Enum.flat_map(ongekeurd, fn w -> ruwe_paden(ctx, w) ++ keur_paden(ctx, w) end)

      assert lekken(paden, ctx.sleutels.lees, ongekeurd) == []
    end

    test "een werksleutel vindt ze op geen enkel zoekpad over memories, chunks of bronnen", ctx do
      ongekeurd = [ctx.woorden.open, ctx.woorden.afgewezen, ctx.woorden.ingetrokken]
      paden = Enum.flat_map(ongekeurd, &ruwe_paden(ctx, &1))

      assert lekken(paden, ctx.sleutels.werk, ongekeurd) == []
    end

    test "de beheersleutel houdt de zoekpaden", ctx do
      conn =
        vraag(:get, "/api/memory?workspace=#{ctx.ws}&q=#{ctx.woorden.open}", ctx.sleutels.beheer)

      assert conn.status == 200
      assert conn.resp_body =~ ctx.woorden.open
    end
  end

  describe "gekeurd blijft vindbaar" do
    test "een agentsleutel vindt het gekeurde feit in de feiten, het zoeken en de goedgekeurde claims",
         ctx do
      w = ctx.woorden.gekeurd

      feiten = vraag(:get, "/api/memory-core/facts?workspace=#{ctx.ws}", ctx.sleutels.lees)
      assert feiten.status == 200
      assert feiten.resp_body =~ w

      zoek =
        vraag(:post, "/api/memory-core/facts/search", ctx.sleutels.lees, %{
          "q" => w,
          "workspace" => ctx.ws
        })

      assert zoek.status == 200
      assert zoek.resp_body =~ w

      claims =
        vraag(
          :get,
          "/api/memory-core/claim-review?workspace=#{ctx.ws}&review_status=approved",
          ctx.sleutels.lees
        )

      assert claims.status == 200
      assert claims.resp_body =~ w
    end

    test "de werksleutel plaatst nog en ziet de keurlijst", ctx do
      wachtrij =
        vraag(
          :get,
          "/api/memory-core/claim-review?workspace=#{ctx.ws}&review_status=unreviewed",
          ctx.sleutels.werk
        )

      assert wachtrij.status == 200
      assert wachtrij.resp_body =~ ctx.woorden.open
    end

    test "een agentsleutel krijgt bij een ongekeurd pad een 403 met de reden", ctx do
      conn = vraag(:get, "/api/search?q=#{ctx.woorden.open}&workspace=#{ctx.ws}", ctx.sleutels.lees)
      assert conn.status == 403
      assert Jason.decode!(conn.resp_body)["error"] == "alleen_gekeurde_feiten"

      conn = vraag(:get, "/api/search?q=#{ctx.woorden.open}&workspace=#{ctx.ws}", ctx.sleutels.werk)
      assert conn.status == 403
      assert Jason.decode!(conn.resp_body)["error"] == "beheersleutel_vereist"
    end
  end
end

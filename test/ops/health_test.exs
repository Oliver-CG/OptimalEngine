defmodule OptimalEngine.HealthTest do
  use ExUnit.Case, async: false

  alias OptimalEngine.Health

  test "live?/0 returns true while the supervisor is running" do
    assert Health.live?()
  end

  test "ready/1 returns a status map with declared checks" do
    r = Health.ready(skip: [:embedder])
    assert is_map(r)
    assert Map.has_key?(r, :ok?)
    assert Map.has_key?(r, :checks)
    assert Map.has_key?(r, :degraded)

    # store + migrations should be :ok when supervisor is running
    assert r.checks.store == :ok
    assert r.checks.migrations == :ok
  end

  test "status/0 returns a known atom" do
    # Tests run with connectors registered but no CONNECTOR_KEY — the
    # credential check may be :error, so :down is a valid outcome here.
    assert Health.status() in [:up, :degraded, :down]
  end

  test "ready/1 honors the :skip option" do
    r = Health.ready(skip: [:embedder, :credential_key])
    refute Map.has_key?(r.checks, :embedder)
    refute Map.has_key?(r.checks, :credential_key)
  end
end

defmodule OptimalEngine.Ops.HealthcheckStringTest do
  @moduledoc """
  De Docker-HEALTHCHECK greptte tot 22-09 niet: `wget … || exit 1` slaagde
  altijd, want /api/health geeft bewust ook bij ok? false een HTTP 200 (het is
  een keyless, extern gedocumenteerd oppervlak). "healthy" zei dus alleen
  "de poort staat open".

  Deze toets bindt de letterlijke string uit de Dockerfile aan wat de route
  encodeert: hij leest het grep-patroon uít de Dockerfiles en houdt het tegen
  een gezond en een geplant ziek rapport.
  """
  use ExUnit.Case, async: true

  alias OptimalEngine.Health

  # Beide worden gebouwd: .poc is wat higgi-ci naar ghcr duwt.
  @dockerfiles ["deploy/Dockerfile.engine", "deploy/Dockerfile.engine.poc"]

  # Zoals lib/optimal_engine/api/router.ex "/api/health" het antwoord bouwt.
  defp health_body(report) do
    Jason.encode!(%{
      status: :degraded,
      live: true,
      ok?: report.ok?,
      degraded: report.degraded,
      checks: Map.new(report.checks, fn {k, v} -> {k, inspect(v)} end)
    })
  end

  defp grep_patroon(pad) do
    line =
      pad
      |> File.read!()
      |> String.split("\n")
      |> Enum.find("", &String.contains?(&1, "/api/health"))

    case Regex.run(~r/grep -q '([^']+)'/, line) do
      [_, patroon] -> patroon
      nil -> flunk("#{pad}: de HEALTHCHECK grept nergens op — hij kan niet falen")
    end
  end

  test "de HEALTHCHECK van elke Dockerfile grept op een patroon" do
    for pad <- @dockerfiles do
      assert grep_patroon(pad) == ~S("ok?":true)
    end
  end

  test "het patroon zit wél in een gezond rapport en niét in een geplant ziek rapport" do
    gezond = %{ok?: true, checks: %{store: :ok, migrations: :ok}, degraded: []}

    ziek = %{
      ok?: false,
      checks: %{store: {:error, :store_unreachable}, migrations: :ok},
      degraded: []
    }

    for pad <- @dockerfiles do
      patroon = grep_patroon(pad)

      assert health_body(gezond) =~ patroon
      refute health_body(ziek) =~ patroon
    end
  end

  test "het geplante rapport heeft dezelfde vorm als een echt rapport" do
    echt = Health.ready(skip: [:embedder])
    assert Enum.sort(Map.keys(echt)) == [:checks, :degraded, :ok?]
  end
end

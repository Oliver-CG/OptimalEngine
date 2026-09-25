# Mints the three read keys that give each brain client its own rate-limit
# bucket (F3, 25-09) and prints them as one JSON object. Run inside the release
# container, stdout straight into a 0600 file, never onto a terminal:
#
#   bin/optimal rpc 'Code.eval_file("/scripts/mint_read_keys.exs")'
#
#   kern-ronde — ronde, wekker, oogst (the live chain)
#   schil      — the schil container
#   scripts    — hub, agents, measurements
#
# The limit of a key is fixed at mint (metadata); changing it means a new key.
# Override per key with OE_GRENS_KERN / OE_GRENS_SCHIL / OE_GRENS_SCRIPTS as
# "<per_minute>:<burst>". Without an override the defaults below apply.

alias OptimalEngine.Auth.ApiKey

instance =
  System.get_env("OE_INSTANCE") ||
    raise "OE_INSTANCE is not set — expected the klant slug (wonders, ruiterhuys, ...)"

grens = fn env, default ->
  case System.get_env(env) do
    nil ->
      default

    raw ->
      [rpm, burst] = raw |> String.split(":") |> Enum.map(&String.to_integer/1)
      {rpm, burst}
  end
end

mint = fn rol, {rpm, burst} ->
  {:ok, %{key: key}} =
    ApiKey.mint(%{
      tenant_id: "default",
      name: "#{instance}: #{rol} (lezen)",
      scopes: ["read"],
      metadata: %{"rate_limit_per_minute" => rpm, "rate_limit_burst" => burst}
    })

  key
end

keys = %{
  "kern-ronde" => mint.("kern-ronde", grens.("OE_GRENS_KERN", {120, 60})),
  "schil" => mint.("schil", grens.("OE_GRENS_SCHIL", {300, 200})),
  "scripts" => mint.("scripts", grens.("OE_GRENS_SCRIPTS", {60, 30}))
}

IO.puts(Jason.encode!(keys))

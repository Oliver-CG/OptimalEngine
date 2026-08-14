# Mints the three keys a per-klant instance needs and prints them as one JSON
# object. Run inside the release container (mix does not exist there):
#
#   bin/optimal rpc 'Code.eval_file("/scripts/mint_instance_keys.exs")'
#
# Three keys, three roles (see ~/HiggiHQ/strategy/KLANTSERVER-PLAN.md):
#   admin   — box-only ops (rotation, revocation). Never leaves the box.
#   intake  — the feed. Scripts post claims with this key; its principal becomes
#             the evaluator on every claim it creates, so the self-review
#             refusal blocks the feed from ever approving itself.
#   cockpit — the approve path: read/write and NO admin (since the admin-scope
#             fix a key cannot mint itself an upgrade). Principal user:oliver,
#             so every promotion is signed by a person with a name.
#
# Principals must exist before minting — api_keys carries a foreign key, and
# since fix(store) a violated constraint is a loud error, not a silent drop.

alias OptimalEngine.Auth.ApiKey
alias OptimalEngine.Identity.Principal

instance =
  System.get_env("OE_INSTANCE") ||
    raise "OE_INSTANCE is not set — expected the klant slug (wonders, ruiterhuys, ...)"

{:ok, _} =
  Principal.upsert(%{
    id: "system:intake-dagrapport",
    kind: :service,
    display_name: "Intake dagrapport (#{instance})"
  })

{:ok, _} =
  Principal.upsert(%{
    id: "user:oliver",
    kind: :user,
    display_name: "Oliver Higgins"
  })

{:ok, %{key: admin}} =
  ApiKey.mint(%{
    tenant_id: "default",
    name: "#{instance}: admin (box-only)",
    scopes: ["admin"]
  })

{:ok, %{key: intake}} =
  ApiKey.mint(%{
    tenant_id: "default",
    name: "#{instance}: intake",
    principal_id: "system:intake-dagrapport",
    scopes: ["read", "write"]
  })

{:ok, %{key: cockpit}} =
  ApiKey.mint(%{
    tenant_id: "default",
    name: "#{instance}: cockpit",
    principal_id: "user:oliver",
    scopes: ["read", "write"]
  })

IO.puts(Jason.encode!(%{admin: admin, intake: intake, cockpit: cockpit}))

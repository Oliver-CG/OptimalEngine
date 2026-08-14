# Mints the four throwaway keys promote_toets_v2.sh needs and prints them as
# one JSON object. Run against the SAME database the engine will serve:
#
#   local/CI :  mix run test/acceptance/mint_toets_keys.exs
#   release  :  bin/optimal rpc 'Code.eval_file("test/acceptance/mint_toets_keys.exs")'
#               (or paste the body into `bin/optimal remote`)
#
# The keys are real rows; revoke them after the toets or archive the instance.
# Principals must exist before a key can reference them — the api_keys table
# carries a foreign key, and since fix(store) a violated constraint is a loud
# error instead of a silently dropped write.

alias OptimalEngine.Auth.ApiKey
alias OptimalEngine.Identity.Principal

{:ok, _} =
  Principal.upsert(%{
    id: "user:toets-reviewer",
    kind: :user,
    display_name: "Toets Reviewer"
  })

# The memory-create bridge is the evaluator on every claim that
# POST /api/memory produces. A key with that principal lets the toets prove
# the self-review refusal fires on the live path.
{:ok, _} =
  Principal.upsert(%{
    id: "system:memory-create-bridge",
    kind: :service,
    display_name: "Memory Create Bridge (toets-imitatie)"
  })

{:ok, %{key: service}} =
  ApiKey.mint(%{
    tenant_id: "default",
    name: "toets: service, geen principal",
    scopes: ["read", "write"]
  })

{:ok, %{key: reviewer}} =
  ApiKey.mint(%{
    tenant_id: "default",
    name: "toets: reviewer",
    principal_id: "user:toets-reviewer",
    scopes: ["read", "write"]
  })

{:ok, %{key: bridge}} =
  ApiKey.mint(%{
    tenant_id: "default",
    name: "toets: bridge-imitatie",
    principal_id: "system:memory-create-bridge",
    scopes: ["read", "write"]
  })

{:ok, %{key: admin}} =
  ApiKey.mint(%{
    tenant_id: "default",
    name: "toets: admin",
    scopes: ["admin"]
  })

IO.puts(Jason.encode!(%{service: service, reviewer: reviewer, bridge: bridge, admin: admin}))

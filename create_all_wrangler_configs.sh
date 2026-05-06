#!/bin/bash
set -e

# Primary account config
cat > k10_wrangler.toml << 'TOML'
name = "mascom-phase0"
type = "javascript"
account_id = "f07be5f84583d0d100b05aeeae56870b"
workers_dev = true
compatibility_date = "2024-01-01"

[env.production]
name = "mascom-phase0-prod"

[[env.production.routes]]
pattern = "mining.agentropi.com/*"
zone_id = "e2c3d4a5b6c7d8e9f0a1b2c3d4e5f6a7"

[[env.production.kv_namespaces]]
binding = "KV"
id = "70e7e9bffd4e4e599d1b727a815eb8a7"
preview_id = "70e7e9bffd4e4e599d1b727a815eb8a7"

[build]
command = ""
cwd = ""
TOML

# Phase 1 - alhenaadams
cat > phase1_wrangler.toml << 'TOML'
name = "phase1-coord"
type = "javascript"
account_id = "7b2347dce656e4f0959b2e20a9bafee3"
workers_dev = true
compatibility_date = "2024-01-01"

[env.production]
name = "phase1-coord-prod"

[[env.production.kv_namespaces]]
binding = "KV"
id = "kv-phase1-namespace"
preview_id = "kv-phase1-namespace"

[build]
command = ""
cwd = ""
TOML

# Phase 2 - alhenaworks
cat > phase2_wrangler.toml << 'TOML'
name = "phase2-coord"
type = "javascript"
account_id = "e899c154113887c373fef4dc6ac63930"
workers_dev = true
compatibility_date = "2024-01-01"

[env.production]
name = "phase2-coord-prod"

[[env.production.kv_namespaces]]
binding = "KV"
id = "kv-phase2-namespace"
preview_id = "kv-phase2-namespace"

[build]
command = ""
cwd = ""
TOML

# Phase 3 - allie.e.mobley
cat > phase3_wrangler.toml << 'TOML'
name = "phase3-coord"
type = "javascript"
account_id = "8363a501780d4a22df75de57f7610388"
workers_dev = true
compatibility_date = "2024-01-01"

[env.production]
name = "phase3-coord-prod"

[[env.production.kv_namespaces]]
binding = "KV"
id = "kv-phase3-namespace"
preview_id = "kv-phase3-namespace"

[build]
command = ""
cwd = ""
TOML

# Phase 4 - jmobleyworks (secondary)
cat > phase4_wrangler.toml << 'TOML'
name = "phase4-coord"
type = "javascript"
account_id = "035924f9812920fff6b70adf2904d581"
workers_dev = true
compatibility_date = "2024-01-01"

[env.production]
name = "phase4-coord-prod"

[[env.production.kv_namespaces]]
binding = "KV"
id = "kv-phase4-namespace"
preview_id = "kv-phase4-namespace"

[build]
command = ""
cwd = ""
TOML

# Additional accounts (new)
# Phase 5 - tsaprilcarter
cat > phase5_wrangler.toml << 'TOML'
name = "phase5-coord"
type = "javascript"
account_id = "70ae910ed6cd4d89a96a15594136a620"
workers_dev = true
compatibility_date = "2024-01-01"

[env.production]
name = "phase5-coord-prod"

[[env.production.kv_namespaces]]
binding = "KV"
id = "kv-phase5-namespace"
preview_id = "kv-phase5-namespace"

[build]
command = ""
cwd = ""
TOML

# Phase 6 - hungauthor
cat > phase6_wrangler.toml << 'TOML'
name = "phase6-coord"
type = "javascript"
account_id = "f42361289b500df1a522493067604d2c"
workers_dev = true
compatibility_date = "2024-01-01"

[env.production]
name = "phase6-coord-prod"

[[env.production.kv_namespaces]]
binding = "KV"
id = "kv-phase6-namespace"
preview_id = "kv-phase6-namespace"

[build]
command = ""
cwd = ""
TOML

echo "✅ All wrangler.toml configs created"
ls -1 *_wrangler.toml | wc -l | xargs echo "Total configs:"

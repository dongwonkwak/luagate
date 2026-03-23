# LuaGate Demo
# Record with VHS: https://github.com/charmbracelet/vhs
#
# Usage:
#   nix-shell -p vhs    # or: go install github.com/charmbracelet/vhs@latest
#   vhs docs/assets/demo.tape
#
# Output: docs/assets/demo.gif

Output docs/assets/demo.gif

Require echo
Require curl
Require make
Require jq

Set Shell "bash"
Set FontSize 14
Set Width 900
Set Height 500
Set Theme "Catppuccin Mocha"
Set Padding 20

# Title
Type "# LuaGate — Policy-driven API Security Gateway"
Enter
Sleep 1s

# Step 0: Create .env (Admin API token required)
Type "echo 'LUAGATE_ADMIN_TOKEN=demo-token-at-least-32-bytes-long!!' > .env"
Enter
Sleep 1s

# Step 1: Start LuaGate
Type "make up"
Enter
Sleep 8s

# Step 2: Health check (Admin API, no auth required)
Type "# Health check"
Enter
Sleep 500ms
Type 'curl -s http://localhost:9090/health | jq .'
Enter
Sleep 2s

# Step 3: Gateway request — policy deny (403)
Type "# Gateway request — expect 403 (policy deny)"
Enter
Sleep 500ms
Type 'curl -s -w "\nHTTP %{http_code}\n" http://localhost:8080/admin/secret | jq .'
Enter
Sleep 2s

# Step 4: Hot reload (zero-downtime)
Type "# Hot reload policy (zero-downtime, no nginx restart)"
Enter
Sleep 500ms
Type 'curl -s -X POST http://localhost:9090/api/v1/policies/reload -H "Authorization: Bearer $LUAGATE_ADMIN_TOKEN" | jq .'
Enter
Sleep 2s

# Step 5: Verify reload — policy version
Type "# Verify — policy version updated"
Enter
Sleep 500ms
Type 'curl -s http://localhost:9090/api/v1/policies/version | jq .'
Enter
Sleep 2s

# Step 6: Prometheus metrics
Type "# Prometheus metrics"
Enter
Sleep 500ms
Type 'curl -s http://localhost:9090/metrics | grep luagate_ | head -10'
Enter
Sleep 3s

# Cleanup
Type "make down"
Enter
Sleep 3s

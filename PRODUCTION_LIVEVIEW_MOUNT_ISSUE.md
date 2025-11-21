# Production LiveView Mount Failure - Movies Page

## Issue Summary

In production (https://cinegraph.org/movies), the page loads instantly but displays an infinite blue progress bar at the top, indicating that the LiveView connection never successfully establishes.

## Root Cause Analysis

Using Playwright to analyze production network traffic, the following sequence was discovered:

### 1. WebSocket Connection Fails
```
[ERROR] WebSocket connection to 'wss://cinegraph.org/live/websocket?_csrf_token=...' [FAILED]
```

### 2. Automatic Fallback to Long Polling (Working)
LiveView correctly falls back to HTTP long polling:
- All `/live/longpoll` requests return **200 OK**
- Transport mechanism is working correctly

### 3. LiveView Mount Never Succeeds (CRITICAL)
Analyzing the request parameters across 47+ retry attempts:
- `_mounts=0` - **Stays at zero throughout all requests** ❌
- `_mount_attempts=0→1→2→3...→47` - **Keeps incrementing** ❌

**This means the LiveView session is continuously attempting to mount but never succeeding.**

## Why the Page "Appears" to Work

1. ✅ Initial HTTP render completes successfully (static HTML)
2. ✅ Page displays all movies correctly
3. ✅ Long polling transport works
4. ❌ LiveView stateful session never establishes
5. 🔄 Blue progress bar shows LiveView retrying mount forever

## Evidence

**Network Pattern (simplified)**:
```
GET /live/longpoll?_mounts=0&_mount_attempts=0
GET /live/longpoll?_mounts=0&_mount_attempts=1
GET /live/longpoll?_mounts=0&_mount_attempts=2
GET /live/longpoll?_mounts=0&_mount_attempts=3
... (continues forever)
```

**Key observation**: `_mounts` never increments from 0.

## Likely Causes

### 1. Infrastructure/Proxy Issues
- **Load balancer/proxy blocking WebSocket upgrades**
- Sticky session issues preventing long polling from working correctly
- CSRF token validation failing in production
- Different domain/subdomain configuration

### 2. Production Environment Configuration
- Check Phoenix Endpoint configuration in `config/prod.exs`
- Verify `url` and `check_origin` settings
- Ensure session cookies are being set correctly

### 3. Mount Lifecycle Errors
- Something in `MovieLive.Index.mount/3` failing silently in production
- Database connection timeout during mount
- Missing environment variables or configuration

## Investigation Steps

### 1. Check Production Logs
Look for errors during LiveView mount:
```bash
# On production server
tail -f /var/log/phoenix/production.log | grep -i "mount\|liveview\|websocket"
```

### 2. Verify Endpoint Configuration
Check `config/prod.exs`:
```elixir
config :cinegraph, CinegraphWeb.Endpoint,
  url: [host: "cinegraph.org", port: 443, scheme: "https"],
  check_origin: ["https://cinegraph.org"],
  # Ensure these are set correctly for WebSocket/long polling
  http: [protocol_options: [idle_timeout: :infinity]],
  server: true
```

### 3. Check Load Balancer/Proxy
- Verify WebSocket upgrade headers are being forwarded
- Check for timeouts on WebSocket connections
- Ensure sticky sessions for long polling

### 4. Test Mount Function Directly
Add logging to `lib/cinegraph_web/live/movie_live/index.ex`:
```elixir
def mount(_params, _session, socket) do
  Logger.info("[MovieLive.Index] Starting mount")

  # Existing mount logic...

  Logger.info("[MovieLive.Index] Mount completed successfully")
  {:ok, socket}
rescue
  e ->
    Logger.error("[MovieLive.Index] Mount failed: #{inspect(e)}")
    reraise e, __STACKTRACE__
end
```

### 5. Check Browser Console
In production, open browser console and look for LiveView errors:
```javascript
// Check LiveView socket status
window.liveSocket.isConnected() // Should be true
```

## Impact

- **User Experience**: Page appears "stuck loading" despite being functional
- **Interactivity**: LiveView features (filters, sorting, pagination) may not work correctly without stateful connection
- **Performance**: Continuous retry attempts waste bandwidth

## Priority

**HIGH** - While the page renders, the LiveView connection failure breaks real-time features and creates poor UX with the infinite loading bar.

## Related Files

- `lib/cinegraph_web/live/movie_live/index.ex` - Mount logic
- `config/prod.exs` - Production endpoint configuration
- `lib/cinegraph_web/endpoint.ex` - Endpoint setup
- Infrastructure: Load balancer/reverse proxy configuration

## Next Steps

1. Check production logs for mount errors
2. Verify endpoint configuration for WebSocket support
3. Test WebSocket connectivity from production environment
4. Add detailed logging to mount function
5. Review infrastructure (Fly.io/proxy) WebSocket configuration

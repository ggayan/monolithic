# Plan: Nginx Configuration to Prevent Invalid Cache Files

## Problem Statement

Users currently face corrupt/invalid cache files that require manual cleanup using slow commands like:
```bash
find /cache -type f -exec awk 'FNR>2 {nextfile} /pattern/ { print FILENAME }' '{}' +
```

This happens because nginx can cache partial or corrupt responses when:
1. Upstream connection drops mid-transfer
2. Network timeout during slice download
3. Upstream sends incomplete response with valid headers
4. nginx restart during active cache population

**Goal**: Configure nginx to prevent corrupt files from being cached in the first place.

---

## How Slice Caching Works (Background)

```
Client Request: GET /game/file.zip (500MB file)
                        │
                        ▼
┌─────────────────────────────────────────────────────────────┐
│                    NGINX SLICE MODULE                        │
│  Splits request into 1MB slices (configured via `slice 1m`) │
└─────────────────────────────────────────────────────────────┘
                        │
        ┌───────────────┼───────────────┐
        ▼               ▼               ▼
   Slice 0-1MB    Slice 1-2MB    Slice 2-3MB  ... (500 slices)
        │               │               │
        ▼               ▼               ▼
   Cache Key:      Cache Key:      Cache Key:
   uri+0-1MB       uri+1-2MB       uri+2-3MB
```

Each slice is:
- Independently fetched from upstream
- Independently cached with its own cache key
- Independently served to clients

**The corruption problem**: If slice #247 fails mid-download, that specific slice file may contain partial data with valid HTTP headers, and nginx will serve it as if it's complete.

---

## Directive-by-Directive Analysis

### 1. `proxy_socket_keepalive on`

**What it does:**
Enables TCP keepalive probes on the connection between nginx and upstream servers.

**Current behavior (without it):**
```
nginx ──────────────────────────────── upstream
         Connection established

         [Upstream silently dies - no FIN/RST sent]

nginx ──── waiting... waiting... ──── (dead)

         [Waits until proxy_read_timeout (default 60s)]
```

When an upstream server crashes, hangs, or has network issues, TCP connections can go "half-open" - nginx thinks the connection is alive but upstream is gone. Without keepalives, nginx waits for the full `proxy_read_timeout` before detecting the failure.

**Behavior with `proxy_socket_keepalive on`:**
```
nginx ──────────────────────────────── upstream
         Connection established

         [Upstream silently dies]

nginx ──── keepalive probe ─────────── (no response)
nginx ──── keepalive probe ─────────── (no response)

         [Connection marked dead much faster]
         [nginx can retry or fail cleanly]
```

TCP keepalive probes (controlled by OS settings, typically every 75s) detect dead connections. This means:
- Faster detection of dead upstreams
- Cleaner connection failures (proper error, not timeout)
- Less chance of partial data being cached

**Impact on corrupt cache prevention:**
- **Medium-High** - Detects dead connections faster, reducing window for partial writes
- **Risk**: None - purely beneficial

---

### 2. `proxy_read_timeout` (propose: 150s, default: 60s)

**What it does:**
Maximum time nginx waits for upstream to send data. If no data received within this window, connection is closed with error.

**Current behavior (default 60s):**
```
Timeline for stuck 1MB slice download:

0s   ─── Request sent to upstream
5s   ─── First 100KB received
10s  ─── Another 200KB received
15s  ─── Connection stalls (upstream overloaded)
...
75s  ─── Still no data (60s timeout from last data)
75s  ─── nginx closes connection, returns error
```

**Why 150s for lancache:**
Game CDNs can be slow, especially during peak times (game launches, LAN parties). 60s is reasonable but 150s provides headroom for:
- Slow CDN responses during high load
- Large file downloads from distant servers
- Burst traffic scenarios

**Trade-off considerations:**
- Too short (30s): May timeout legitimate slow downloads
- Too long (300s+): Delays detection of truly stuck connections
- 150s: Balance between reliability and fast failure detection

**Impact on corrupt cache prevention:**
- **Medium** - Ensures stuck connections are killed, triggering retry logic
- **Risk**: Low - may need tuning based on real-world CDN performance

---

### 3. `proxy_connect_timeout` (propose: 10s, default: 60s)

**What it does:**
Maximum time nginx waits to establish a TCP connection to upstream.

**Current behavior (default 60s):**
```
nginx ─── SYN ──────────────────────── upstream (unreachable)
         [Waits 60 seconds]
         Connection failed
```

**With 10s timeout:**
```
nginx ─── SYN ──────────────────────── upstream (unreachable)
         [Waits 10 seconds]
         Connection failed → triggers proxy_next_upstream
```

**Why 10s is sufficient:**
- TCP connection establishment should be fast (< 1s typically)
- If a CDN can't accept connection in 10s, it's likely down
- Faster failure = faster retry to alternate resolution

**Impact on corrupt cache prevention:**
- **Low-Medium** - Doesn't directly prevent corruption, but speeds up failure/retry cycle
- **Risk**: Very low - 10s is generous for connection establishment

---

### 4. `proxy_cache_lock_age` (propose: 30s, current: 2m)

**What it does:**
When cache lock is enabled, only one request fetches a given cache entry. Other requests wait. `proxy_cache_lock_age` controls how long before nginx allows another request to try fetching.

**Current behavior (2 minutes):**
```
Request A: GET /game/slice_247 (cache miss, starts fetching)
           [Lock acquired for slice_247]

Request B: GET /game/slice_247 (same slice)
           [Waiting for lock... Request A has it]

           ... Request A stalls at 50% downloaded ...

           [After 2 MINUTES, lock expires]

Request B: [Lock released, B can now fetch]
```

If Request A's download is corrupt/stuck, every other client waits 2 full minutes before anyone can retry.

**With 30s lock age:**
```
Request A: GET /game/slice_247 (cache miss, starts fetching)
           [Lock acquired]

Request B: GET /game/slice_247 (waiting...)

           ... Request A stalls ...

           [After 30 SECONDS, lock expires]

Request B: [Can now fetch fresh copy]
```

**Why 30s for 1MB slices:**
- A healthy 1MB download should complete in < 10s on most connections
- 30s provides 3x headroom for slow connections
- If a slice takes > 30s, something is likely wrong

**Relationship with slice size:**
```
slice_size = 1MB
expected_download_time = 1MB / bandwidth

At 10 Mbps:  ~0.8 seconds
At 1 Mbps:   ~8 seconds
At 100 Kbps: ~80 seconds (very slow upstream)

30s covers most scenarios except extremely slow connections
```

**Impact on corrupt cache prevention:**
- **HIGH** - This is one of the most important changes
- Faster recovery when a download gets stuck
- Other clients can retry and potentially get good copy
- **Risk**: May cause duplicate upstream requests if legitimately slow

---

### 5. `proxy_cache_lock_timeout` (propose: 3m, current: 1h)

**What it does:**
Absolute maximum time a request will wait for cache lock before bypassing the lock entirely and fetching directly (uncached).

**Current behavior (1 hour!):**
```
Request A: Starts fetching, gets stuck
Request B: Waits for lock...

           [proxy_cache_lock_age expires after 2m]

Request B: Tries to fetch, also gets stuck
Request C: Waits for lock...

           [Cycle continues for up to 1 HOUR]

           Finally: Requests bypass cache entirely
```

This 1 hour timeout is extremely conservative. If something is broken, users wait up to an hour before the system gives up and bypasses cache.

**With 3 minute timeout:**
```
Request A: Starts fetching, gets stuck

           [After 3 minutes total]

All waiting requests: "Cache is broken, fetching directly"
           [Bypass cache, get file from upstream]
```

**Why 3 minutes:**
- Even the largest slice (1MB) should download in < 3m
- Provides enough time for `proxy_cache_lock_age` to cycle a few times
- Prevents hour-long waits when cache population is truly broken

**Impact on corrupt cache prevention:**
- **HIGH** - Prevents prolonged serving of corrupt content
- System recovers within minutes instead of hours
- **Risk**: More cache bypasses under extreme load (acceptable trade-off)

---

### 6. `proxy_next_upstream` Enhancement

**Current configuration:**
```nginx
proxy_next_upstream error timeout http_404;
```

**Proposed configuration:**
```nginx
proxy_next_upstream error timeout http_404 http_500 http_502 http_503 http_504 invalid_header;
proxy_next_upstream_tries 3;
proxy_next_upstream_timeout 0;
```

**What each parameter does:**

**`proxy_next_upstream` conditions:**
| Condition | Meaning |
|-----------|---------|
| `error` | Connection error occurred |
| `timeout` | Timeout during connection/read/write |
| `http_404` | Upstream returned 404 (current) |
| `http_500` | Upstream returned 500 Internal Server Error |
| `http_502` | Upstream returned 502 Bad Gateway |
| `http_503` | Upstream returned 503 Service Unavailable |
| `http_504` | Upstream returned 504 Gateway Timeout |
| `invalid_header` | **KEY** - Upstream returned invalid/empty response |

**`invalid_header` is critical:**
```
Scenario: Upstream starts sending response, then dies

nginx receives:
  HTTP/1.1 200 OK
  Content-Length: 1048576
  [connection drops - no body]

Without invalid_header: nginx may cache this partial response
With invalid_header: nginx detects invalid response, retries
```

**`proxy_next_upstream_tries 3`:**
Retry up to 3 times before giving up. This means:
```
Attempt 1: upstream-a.cdn.com → fails
Attempt 2: upstream-b.cdn.com → fails
Attempt 3: upstream-c.cdn.com → success!
```

For lancache with single upstream, this means:
```
Attempt 1: origin server → timeout
Attempt 2: origin server → success (transient issue resolved)
```

**`proxy_next_upstream_timeout 0`:**
No overall timeout for retry cycle. Each individual attempt has its own timeout, but the retry process itself isn't time-limited.

**Impact on corrupt cache prevention:**
- **HIGH** - `invalid_header` catches partial/corrupt responses before caching
- Automatic retry logic recovers from transient failures
- **Risk**: More upstream requests during failure scenarios (desired behavior)

---

### 7. `proxy_cache_background_update on`

**What it does:**
When serving stale cached content, nginx fetches a fresh copy in the background.

**Current behavior (without it):**
```
Client A: GET /game/file.zip (cache HIT, but entry is stale)
          [Serves stale content immediately]
          [Does NOT refresh cache]

Client B: GET /game/file.zip (same stale entry)
          [Serves same stale content]
          [Still no refresh unless cache lock triggers]
```

**With background update:**
```
Client A: GET /game/file.zip (cache HIT, stale)
          [Serves stale content immediately]
          [ALSO starts background fetch for fresh copy]

          ... background update completes ...

Client B: GET /game/file.zip
          [Serves fresh cached content]
```

**How this helps with corrupt cache:**
If a cache entry becomes corrupt (partial data), and `proxy_cache_use_stale` serves it:
- Without background update: Corrupt entry continues being served indefinitely
- With background update: Fresh copy fetched in background, replaces corrupt entry

**Self-healing behavior:**
```
Corrupt slice in cache
         │
         ▼
Client requests slice
         │
         ▼
Stale/corrupt content served (unfortunately)
         │
         ▼
Background update triggered
         │
         ▼
Fresh, valid slice fetched from upstream
         │
         ▼
Corrupt cache entry REPLACED with valid one
         │
         ▼
Next client gets valid content
```

**Impact on corrupt cache prevention:**
- **MEDIUM-HIGH** - Doesn't prevent initial corruption, but auto-heals
- Corrupt entries get replaced without manual intervention
- **Risk**: Increased upstream bandwidth (acceptable for cache health)

---

### 8. `proxy_cache_use_stale` Adjustment (Optional - More Aggressive)

**Current configuration:**
```nginx
proxy_cache_use_stale error timeout invalid_header updating http_500 http_502 http_503 http_504;
```

**Conservative option:**
```nginx
proxy_cache_use_stale updating http_500 http_502 http_503 http_504;
```

**What changes:**

| Condition | Current | Conservative | Effect |
|-----------|---------|--------------|--------|
| `error` | Serve stale | Retry upstream | May fail if upstream down |
| `timeout` | Serve stale | Retry upstream | May fail if upstream slow |
| `invalid_header` | Serve stale | Retry upstream | Forces fresh fetch |
| `updating` | Serve stale | Serve stale | No change |
| `http_5xx` | Serve stale | Serve stale | No change |

**Trade-off:**
```
Permissive (current):
  Upstream error → Serve cached (possibly corrupt) content
  User experience: Fast, but possibly broken content

Conservative:
  Upstream error → Try to fetch fresh content
  User experience: Slower, but more likely to get valid content
```

**Recommendation:**
Keep current settings but add `proxy_cache_background_update on`. This gives:
- Fast response (serve stale)
- Self-healing (background refresh)
- Best of both worlds

**Impact on corrupt cache prevention:**
- **MEDIUM** - Removing `error`/`timeout` from stale conditions forces refetch
- Trade-off between availability and correctness
- **Risk**: Higher - may cause failures during upstream outages

---

## Implementation Summary

### Files to Modify

**1. `/overlay/etc/nginx/sites-available/cache.conf.d/root/20_cache.conf`**

Add/modify:
```nginx
# Faster lock recovery (currently 2m, propose 30s)
proxy_cache_lock_age 30s;

# Faster total timeout (currently 1h, propose 3m)
proxy_cache_lock_timeout 3m;

# Enable self-healing background updates
proxy_cache_background_update on;
```

**2. `/overlay/etc/nginx/sites-available/cache.conf.d/root/90_upstream.conf`**

Add/modify:
```nginx
# Detect dead connections faster
proxy_socket_keepalive on;

# Explicit timeouts
proxy_connect_timeout 10s;
proxy_read_timeout 150s;
proxy_send_timeout 60s;

# Enhanced retry logic with invalid_header detection
proxy_next_upstream error timeout http_404 http_500 http_502 http_503 http_504 invalid_header;
proxy_next_upstream_tries 3;
proxy_next_upstream_timeout 0;
```

---

## Expected Outcomes

### Before (Current State)
```
Corrupt slice scenario:
1. Upstream drops mid-transfer
2. Partial slice cached with valid headers
3. nginx serves corrupt slice to all clients
4. Cache lock blocks retries for 2 minutes
5. If still broken, waits up to 1 hour
6. Manual intervention required (find + awk + rm)
```

### After (With Changes)
```
Same scenario with new config:
1. Upstream drops mid-transfer
2. proxy_socket_keepalive detects dead connection faster
3. invalid_header triggers retry (up to 3 attempts)
4. If retry fails, lock released after 30s for next request
5. If still broken, cache bypassed after 3 minutes
6. proxy_cache_background_update refreshes stale entries automatically
7. Self-healing - no manual intervention needed
```

### Metrics to Monitor

After implementing, monitor these nginx variables in logs:
- `$upstream_cache_status` - Track HIT/MISS/STALE/BYPASS ratios
- `$upstream_status` - Monitor upstream response codes
- `$upstream_response_time` - Detect slow upstreams

---

## Risk Assessment

| Change | Risk Level | Mitigation |
|--------|------------|------------|
| `proxy_socket_keepalive on` | None | Pure benefit |
| `proxy_connect_timeout 10s` | Very Low | 10s is generous |
| `proxy_read_timeout 150s` | Low | Can increase if needed |
| `proxy_cache_lock_age 30s` | Medium | May cause more upstream requests |
| `proxy_cache_lock_timeout 3m` | Low | Still provides good caching |
| `proxy_next_upstream ... invalid_header` | Low | Desired retry behavior |
| `proxy_cache_background_update on` | Low | Slight bandwidth increase |

**Overall Risk: LOW** - These are conservative changes that improve reliability without fundamentally changing caching behavior.

---

## Questions Before Implementation

1. Should `proxy_cache_use_stale` be made more conservative (remove `error timeout invalid_header`)?
   - Pro: Forces fresh fetch on errors
   - Con: May cause failures during upstream outages

2. Are the timeout values appropriate for your network/CDN conditions?
   - `proxy_read_timeout 150s` - sufficient for slow CDNs?
   - `proxy_cache_lock_age 30s` - appropriate for 1MB slices?

3. Should these be configurable via environment variables (like other settings)?

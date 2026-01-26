#!/bin/bash
# Analyze logs to find potentially corrupt cache entries
# Looks for patterns indicating incomplete/failed downloads that may have been cached
#
# Usage: find-suspect-cache.sh [hours_to_lookback]
# Example: find-suspect-cache.sh 24
#
# Note: This script parses the text log format. For more robust parsing,
# consider using jq to parse the JSON log format instead:
#   jq -r 'select(.upstream_cache_status=="MISS" and .upstream_status=="502")' access.json.log

set -e

LOG_FILE="${LOG_FILE:-/data/logs/access.log}"
LOOKBACK_HOURS="${1:-${LOOKBACK_HOURS:-24}}"
SLICE_SIZE="${SLICE_SIZE:-1048576}"  # 1MB default slice size

echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║           LANCACHE SUSPECT CACHE ANALYZER                        ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo ""
echo "Log file: $LOG_FILE"
echo "Looking back: ${LOOKBACK_HOURS} hours"
echo "Expected slice size: ${SLICE_SIZE} bytes"
echo ""

if [ ! -f "$LOG_FILE" ]; then
    echo "Error: Log file not found: $LOG_FILE"
    exit 1
fi

# Calculate lookback timestamp
lookback_date=$(date -d "${LOOKBACK_HOURS} hours ago" "+%d/%b/%Y:%H" 2>/dev/null || date -v-${LOOKBACK_HOURS}H "+%d/%b/%Y:%H" 2>/dev/null)

echo "Analyzing logs since: $lookback_date"
echo ""

# Pattern 1: Upstream 5xx errors that resulted in MISS (might have cached bad data)
echo "═══════════════════════════════════════════════════════════════════"
echo "PATTERN 1: Upstream 5xx errors (potential bad cache entries)"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

upstream_errors=$(grep -E '"MISS".*"50[0-9]"' "$LOG_FILE" 2>/dev/null | tail -50 || true)
if [ -n "$upstream_errors" ]; then
    echo "$upstream_errors" | while read line; do
        # Extract URI
        uri=$(echo "$line" | grep -oP '"GET \K[^"]+' || echo "$line" | grep -oP '"[A-Z]+ \K[^"]+')
        echo "  URI: $uri"
    done | sort | uniq -c | sort -rn | head -20
    echo ""
    echo "  (Showing top 20 URIs with upstream errors)"
else
    echo "  ✓ No upstream 5xx errors found in recent logs"
fi
echo ""

# Pattern 2: Requests with suspiciously small response sizes for MISS
echo "═══════════════════════════════════════════════════════════════════"
echo "PATTERN 2: Small MISS responses (potential truncated cache)"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "Looking for MISS responses smaller than 50% of slice size ($(( SLICE_SIZE / 2 )) bytes)..."
echo ""

# Find MISS entries with small body_bytes_sent
small_responses=$(awk -v threshold=$((SLICE_SIZE / 2)) '
    /"MISS"/ {
        # Find the bytes_sent field (after status code)
        for(i=1; i<=NF; i++) {
            if($i ~ /^[0-9]+$/ && $(i-1) ~ /^[0-9]{3}$/) {
                bytes = $i
                if(bytes > 0 && bytes < threshold) {
                    print $0
                }
                break
            }
        }
    }
' "$LOG_FILE" 2>/dev/null | tail -50 || true)

if [ -n "$small_responses" ]; then
    echo "$small_responses" | while read line; do
        uri=$(echo "$line" | grep -oP '"GET \K[^"]+' || echo "$line" | grep -oP '"[A-Z]+ \K[^"]+')
        bytes=$(echo "$line" | awk '{for(i=1;i<=NF;i++) if($i ~ /^[0-9]+$/ && $(i-1) ~ /^[0-9]{3}$/) print $i}')
        echo "  $bytes bytes: $uri"
    done | sort | uniq -c | sort -rn | head -20
    echo ""
    echo "  (Showing top 20 small MISS responses)"
else
    echo "  ✓ No suspiciously small MISS responses found"
fi
echo ""

# Pattern 3: URIs with both HIT and errors (indicates possibly corrupt cached entry)
echo "═══════════════════════════════════════════════════════════════════"
echo "PATTERN 3: URIs with mixed HIT and errors (corrupt cache indicator)"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

mixed_results=$(awk '
{
    # Extract URI
    if(match($0, /"GET ([^"]+)"/, arr)) {
        uri = arr[1]
    } else if(match($0, /"[A-Z]+ ([^"]+)"/, arr)) {
        uri = arr[1]
    } else {
        next
    }

    # Check cache status and errors
    if($0 ~ /"HIT"/) {
        hits[uri]++
    }
    if($0 ~ /"(MISS|STALE)"/ && $0 ~ /"50[0-9]"/) {
        errors[uri]++
    }
    if($0 ~ / 0 "/) {
        zero_bytes[uri]++
    }
}
END {
    for(uri in hits) {
        if(errors[uri] > 0 || zero_bytes[uri] > 0) {
            printf "%d errors + %d zero-byte + %d hits: %s\n", errors[uri]+0, zero_bytes[uri]+0, hits[uri], uri
        }
    }
}
' "$LOG_FILE" 2>/dev/null | sort -t: -k1 -rn | head -20 || true)

if [ -n "$mixed_results" ]; then
    echo "$mixed_results"
    echo ""
    echo "  ⚠️  These URIs have cache HITs but also errors - may indicate corrupt cache"
else
    echo "  ✓ No URIs found with mixed HIT and error patterns"
fi
echo ""

# Pattern 4: Repeated STALE serving without successful refresh
echo "═══════════════════════════════════════════════════════════════════"
echo "PATTERN 4: Repeated STALE responses (background update may be failing)"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

stale_uris=$(grep '"STALE"' "$LOG_FILE" 2>/dev/null | \
    grep -oP '"GET \K[^"]+' | \
    sort | uniq -c | sort -rn | \
    awk '$1 > 5 {print $1 " occurrences: " $2}' | head -20 || true)

if [ -n "$stale_uris" ]; then
    echo "$stale_uris"
    echo ""
    echo "  ⚠️  These URIs are repeatedly served as STALE"
else
    echo "  ✓ No URIs with excessive STALE responses"
fi
echo ""

# Summary
echo "═══════════════════════════════════════════════════════════════════"
echo "SUMMARY"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "To remove a specific cache entry, use:"
echo "  ./find-cache-file.sh '/path/to/problematic/file' --delete"
echo ""
echo "To monitor cache health in real-time, use:"
echo "  ./cache-health-monitor.sh"
echo ""

#!/bin/bash
# Real-time cache health monitoring
# Watches access log for error patterns and reports statistics
#
# Usage: cache-health-monitor.sh [interval_seconds]
# Example: cache-health-monitor.sh 60

set -e

LOG_FILE="${LOG_FILE:-/data/logs/access.log}"
CHECK_INTERVAL="${1:-${CHECK_INTERVAL:-60}}"

# Error patterns to watch for
# These patterns match the enhanced log format with upstream_status field
declare -A ERROR_PATTERNS=(
    ["upstream_5xx"]='" "50[0-9]"'
    ["upstream_timeout"]='" "-" - [0-9]+\.[0-9]+ -$'
    ["cache_miss"]='"MISS"'
    ["cache_stale"]='"STALE"'
    ["cache_bypass"]='"BYPASS"'
    ["zero_bytes"]=' 0 "'
)

count_pattern() {
    local pattern=$1
    local lines=$2
    echo "$lines" | grep -cE "$pattern" 2>/dev/null || echo "0"
}

print_header() {
    clear
    echo "╔══════════════════════════════════════════════════════════════════╗"
    echo "║           LANCACHE HEALTH MONITOR                                ║"
    echo "║           Refresh: ${CHECK_INTERVAL}s | Log: ${LOG_FILE}                    "
    echo "╚══════════════════════════════════════════════════════════════════╝"
    echo ""
}

print_stats() {
    local recent_lines="$1"
    local total_lines=$(echo "$recent_lines" | wc -l)

    echo "Last ${total_lines} requests (from last 1000 log entries):"
    echo "────────────────────────────────────────────────────────────────────"
    echo ""

    # Cache status breakdown
    echo "CACHE STATUS:"
    local hits=$(count_pattern '"HIT"' "$recent_lines")
    local misses=$(count_pattern '"MISS"' "$recent_lines")
    local stale=$(count_pattern '"STALE"' "$recent_lines")
    local bypass=$(count_pattern '"BYPASS"' "$recent_lines")
    local expired=$(count_pattern '"EXPIRED"' "$recent_lines")

    local hit_pct=0
    if [ "$total_lines" -gt 0 ]; then
        hit_pct=$((hits * 100 / total_lines))
    fi

    printf "  %-12s %6d  (%3d%% hit rate)\n" "HIT:" "$hits" "$hit_pct"
    printf "  %-12s %6d\n" "MISS:" "$misses"
    printf "  %-12s %6d\n" "STALE:" "$stale"
    printf "  %-12s %6d\n" "BYPASS:" "$bypass"
    printf "  %-12s %6d\n" "EXPIRED:" "$expired"
    echo ""

    # Upstream errors
    echo "UPSTREAM ERRORS:"
    local upstream_5xx=$(count_pattern '" "50[0-9]"' "$recent_lines")
    local upstream_4xx=$(count_pattern '" "4[0-9][0-9]"' "$recent_lines")
    local zero_response=$(echo "$recent_lines" | grep -cE ' 0 "' 2>/dev/null || echo "0")

    if [ "$upstream_5xx" -gt 0 ]; then
        printf "  %-12s %6d  ⚠️  UPSTREAM ISSUES\n" "5xx errors:" "$upstream_5xx"
    else
        printf "  %-12s %6d  ✓\n" "5xx errors:" "$upstream_5xx"
    fi
    printf "  %-12s %6d\n" "4xx errors:" "$upstream_4xx"

    if [ "$zero_response" -gt 0 ]; then
        printf "  %-12s %6d  ⚠️  POSSIBLE TRUNCATION\n" "Zero bytes:" "$zero_response"
    else
        printf "  %-12s %6d  ✓\n" "Zero bytes:" "$zero_response"
    fi
    echo ""

    # Response time stats (if available)
    echo "RESPONSE TIMES (from upstream_response_time field):"
    # Note: $upstream_response_time can be comma-separated on retries (e.g., "0.5, 0.3")
    # Extract last value and handle '-' (no upstream) gracefully
    local slow_requests=$(echo "$recent_lines" | awk '
        {
            time = $(NF)
            # Extract last numeric value from comma-separated list
            if(match(time, /[0-9.]+$/)) {
                time = substr(time, RSTART, RLENGTH)
                if(time > 10) count++
            }
        }
        END {print count+0}
    ')
    local very_slow=$(echo "$recent_lines" | awk '
        {
            time = $(NF)
            if(match(time, /[0-9.]+$/)) {
                time = substr(time, RSTART, RLENGTH)
                if(time > 30) count++
            }
        }
        END {print count+0}
    ')

    printf "  %-12s %6d\n" ">10s:" "$slow_requests"
    if [ "$very_slow" -gt 0 ]; then
        printf "  %-12s %6d  ⚠️  VERY SLOW\n" ">30s:" "$very_slow"
    else
        printf "  %-12s %6d  ✓\n" ">30s:" "$very_slow"
    fi
    echo ""

    # Top requested hosts
    echo "TOP CACHE IDENTIFIERS:"
    echo "$recent_lines" | awk -F'[][]' '{print $2}' | sort | uniq -c | sort -rn | head -5 | while read count id; do
        printf "  %-20s %6d\n" "$id:" "$count"
    done
    echo ""

    echo "────────────────────────────────────────────────────────────────────"
    echo "Last updated: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "Press Ctrl+C to exit"
}

# Check if log file exists
if [ ! -f "$LOG_FILE" ]; then
    echo "Error: Log file not found: $LOG_FILE"
    echo "Make sure lancache is running and generating logs."
    exit 1
fi

echo "Starting cache health monitor..."
echo "Log file: $LOG_FILE"
echo "Refresh interval: ${CHECK_INTERVAL}s"
echo ""

while true; do
    # Get recent log lines (last N lines based on typical request rate)
    recent_lines=$(tail -1000 "$LOG_FILE" 2>/dev/null)

    print_header
    print_stats "$recent_lines"

    sleep "$CHECK_INTERVAL"
done

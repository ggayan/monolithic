#!/bin/bash
# Automated cache health daemon
# Monitors logs and automatically removes cache entries that show persistent errors
#
# Usage: cache-health-daemon.sh
#
# Environment variables:
#   DRY_RUN           - Set to "false" to enable actual deletion (default: "true")
#   ERROR_THRESHOLD   - Errors before flagging URI as suspect (default: 5)
#   CONFIRM_THRESHOLD - Confirmation checks before removal (default: 3)
#   CHECK_INTERVAL    - Seconds between checks (default: 300)
#   LOG_FILE          - Path to access log (default: /data/logs/access.log)
#   CACHE_DIR         - Path to cache directory (default: /data/cache/cache)
#   MAX_SCAN_FILES    - Maximum cache files to scan per remediation (default: 100000)
#   PARALLEL_JOBS     - Number of parallel workers for cache search (default: CPU count)

set -e

LOG_FILE="${LOG_FILE:-/data/logs/access.log}"
CACHE_DIR="${CACHE_DIR:-/data/cache/cache}"
STATE_DIR="${STATE_DIR:-/data/cache/.health-state}"
ERROR_THRESHOLD="${ERROR_THRESHOLD:-5}"
CONFIRM_THRESHOLD="${CONFIRM_THRESHOLD:-3}"
CHECK_INTERVAL="${CHECK_INTERVAL:-300}"
DRY_RUN="${DRY_RUN:-true}"
DAEMON_LOG="${DAEMON_LOG:-/data/logs/cache-health-daemon.log}"
MAX_SCAN_FILES="${MAX_SCAN_FILES:-100000}"
PARALLEL_JOBS="${PARALLEL_JOBS:-$(nproc)}"

# Ensure state directory exists
mkdir -p "$STATE_DIR"

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    echo "$msg"
    echo "$msg" >> "$DAEMON_LOG"
}

log_error() {
    log "ERROR: $*"
}

# Hash a URI to create a state filename
uri_to_statefile() {
    local uri="$1"
    echo "$STATE_DIR/$(echo "$uri" | md5sum | cut -d' ' -f1)"
}

# Analyze recent log entries for errors
analyze_logs() {
    log "Analyzing recent log entries..."

    # Get entries from last CHECK_INTERVAL seconds
    local now=$(date +%s)
    local cutoff=$((now - CHECK_INTERVAL))

    # Parse log and find URIs with errors
    # Looking for VERIFIED corruption indicators:
    # 1. Zero-byte responses on MISS (definitely corrupt)
    # 2. TODO: Truncated responses (upstream_response_length << expected)
    #
    # NOTE: We do NOT delete on upstream 5xx errors alone!
    # Reasoning: If upstream is down (503), deleting local valid stale cache
    # removes the only source of content. Serving stale is better than nothing.
    # Only delete cache entries with verified corruption.
    #
    # Note: We scan recent log entries using tail to limit scope.
    # For more precise time filtering, use JSON log format with $msec field.

    # Estimate lines to scan based on CHECK_INTERVAL
    # Assume ~10 requests/sec max = 600 lines per minute
    local lines_to_scan=$((CHECK_INTERVAL * 10))
    [ "$lines_to_scan" -lt 1000 ] && lines_to_scan=1000
    [ "$lines_to_scan" -gt 50000 ] && lines_to_scan=50000

    tail -n "$lines_to_scan" "$LOG_FILE" 2>/dev/null | \
    awk -v threshold="$ERROR_THRESHOLD" -v cutoff="$cutoff" '
    {
        # Extract URI from request field (match up to space before HTTP version)
        # Example: "GET /path/to/file HTTP/1.1" -> captures "/path/to/file"
        if(match($0, /"(GET|HEAD|POST) ([^ ]+) /, arr)) {
            uri = arr[2]
            # Remove query string for grouping
            gsub(/\?.*$/, "", uri)
        } else {
            next
        }

        # Extract cache key from end of log line (after upstream_response_time)
        # Log format: ... $upstream_response_time "$upstream_cache_key"
        # Cache key may be empty/"-" if not a cacheable request
        cache_key = ""
        if(match($0, /"([^"]*)"[[:space:]]*$/, key_arr)) {
            cache_key = key_arr[1]
            # Ignore "-" (no cache key)
            if(cache_key == "-") cache_key = ""
        }

        # Check for error conditions
        is_error = 0

        # Zero-byte response on MISS (verified corruption)
        # This indicates cache population failed and cached empty/partial data
        if($0 ~ /"MISS"/ && $0 ~ / 0 "/) {
            is_error = 1
            error_type[uri] = "zero_bytes"
        }

        # Future: Add truncation detection
        # if(upstream_response_length > 0 && upstream_response_length < expected * 0.5) {
        #     is_error = 1
        #     error_type[uri] = "truncated"
        # }

        if(is_error) {
            errors[uri]++
            # Collect cache keys for this URI (may have multiple slices)
            if(cache_key != "") {
                if(cache_keys[uri] == "") {
                    cache_keys[uri] = cache_key
                } else {
                    # Check if this cache key already recorded (avoid duplicates)
                    if(index(cache_keys[uri], cache_key) == 0) {
                        cache_keys[uri] = cache_keys[uri] "," cache_key
                    }
                }
            }
        }
    }
    END {
        for(uri in errors) {
            if(errors[uri] >= threshold) {
                # Output: uri \t error_count \t error_type \t cache_keys
                print uri "\t" errors[uri] "\t" error_type[uri] "\t" cache_keys[uri]
            }
        }
    }
    ' 2>/dev/null
}

# Delete cache file using cache key (O(1) - instant!)
# Uses MD5 hash of cache key to compute direct file path
# Cache configured with levels=2:2 in proxy_cache_path
delete_by_cache_key() {
    local cache_key="$1"

    # Compute MD5 hash of cache key
    local md5=$(echo -n "$cache_key" | md5sum | cut -d' ' -f1)

    # Extract directory levels (levels=2:2)
    local level1=${md5:(-2)}          # Last 2 characters
    local level2=${md5:(-4):2}        # 2 characters before last 2

    # Construct cache file path
    local cache_file="$CACHE_DIR/$level2/$level1/$md5"

    # Delete if exists
    if [ -f "$cache_file" ]; then
        if rm -f "$cache_file" 2>/dev/null; then
            log "  REMOVED (O(1)): $cache_file"
            return 0
        else
            log_error "  Failed to remove: $cache_file"
            return 1
        fi
    fi

    return 2  # File not found (may have been already deleted or expired)
}

# Optimized cache file search using parallel processing
# NOTE: This is the fallback O(N) method when cache_key is not available
search_and_delete_cache_files() {
    local uri="$1"
    local start_time=$(date +%s)

    # Use parallel search with xargs
    local removed=0
    local scanned=0

    log "Searching cache (max $MAX_SCAN_FILES files with $PARALLEL_JOBS workers)..."
    log "NOTE: Using O(N) scan method - consider enabling cache_key logging for O(1) deletion"

    # Worker function for parallel search
    local worker_code='
    uri_pattern="$1"
    shift
    for file in "$@"; do
        if head -c 2000 "$file" 2>/dev/null | head -3 | grep -qF "$uri_pattern"; then
            echo "$file"
        fi
    done
    '

    # Find and delete matching cache files in parallel
    local found_files
    found_files=$(find "$CACHE_DIR" -type f 2>/dev/null | head -n "$MAX_SCAN_FILES" | \
        ionice -c2 -n7 nice -n15 \
        xargs -P "$PARALLEL_JOBS" -n 100 bash -c "$worker_code" _ "$uri" 2>/dev/null || true)

    if [ -n "$found_files" ]; then
        while IFS= read -r file; do
            if [ -n "$file" ]; then
                if rm -f "$file" 2>/dev/null; then
                    ((removed++))
                    log "  REMOVED: $file"
                else
                    log_error "  Failed to remove: $file"
                fi
            fi
        done <<< "$found_files"
    fi

    local end_time=$(date +%s)
    local elapsed=$((end_time - start_time))

    log "Search complete in ${elapsed}s: removed $removed files"

    # Output count to stdout (not as return code to avoid issues with set -e)
    echo "$removed"
    return 0
}

# Check if URI should be remediated
check_and_remediate() {
    local uri="$1"
    local error_count="$2"
    local error_type="$3"
    local cache_keys="$4"  # Comma-separated list of cache keys (may be empty)

    local state_file=$(uri_to_statefile "$uri")

    # Read or initialize confirmation count and cache keys
    local confirm_count=0
    local stored_keys=""
    if [ -f "$state_file" ]; then
        # State file format: count|cache_key1,cache_key2,...
        local state_data=$(cat "$state_file" 2>/dev/null || echo "0|")
        confirm_count=$(echo "$state_data" | cut -d'|' -f1)
        stored_keys=$(echo "$state_data" | cut -d'|' -f2)
    fi
    ((confirm_count++))

    # Merge new cache keys with stored keys (avoid duplicates)
    if [ -n "$cache_keys" ]; then
        if [ -z "$stored_keys" ]; then
            stored_keys="$cache_keys"
        else
            # Combine and deduplicate
            stored_keys="$stored_keys,$cache_keys"
        fi
    fi

    # Save state
    echo "$confirm_count|$stored_keys" > "$state_file"

    log "SUSPECT: $uri (errors: $error_count, type: $error_type, confirmations: $confirm_count/$CONFIRM_THRESHOLD)"
    if [ -n "$stored_keys" ]; then
        local key_count=$(echo "$stored_keys" | tr ',' '\n' | wc -l)
        log "  Collected $key_count cache key(s) for O(1) deletion"
    fi

    # Check if we've reached confirmation threshold
    if [ "$confirm_count" -ge "$CONFIRM_THRESHOLD" ]; then
        log "CONFIRMED BAD: $uri - initiating remediation"

        if [ "$DRY_RUN" == "true" ]; then
            if [ -n "$stored_keys" ]; then
                local key_count=$(echo "$stored_keys" | tr ',' '\n' | wc -l)
                log "DRY RUN: Would delete $key_count cache files using O(1) method (instant)"
            else
                log "DRY RUN: Would search and delete cache files for: $uri using O(N) scan"

                # Quick estimate using parallel search
                local start_time=$(date +%s)
                local count=$(find "$CACHE_DIR" -type f 2>/dev/null | head -n "$MAX_SCAN_FILES" | \
                    xargs -P "$PARALLEL_JOBS" -n 100 sh -c '
                        for f in "$@"; do
                            head -c 2000 "$f" 2>/dev/null | head -3 | grep -qF "$1" && echo 1
                        done
                    ' _ "$uri" 2>/dev/null | wc -l)
                local end_time=$(date +%s)
                local elapsed=$((end_time - start_time))

                log "DRY RUN: Would delete approximately $count cache files (scanned in ${elapsed}s)"
            fi
        else
            local removed=0

            # Try O(1) deletion first if we have cache keys
            if [ -n "$stored_keys" ]; then
                log "Using O(1) deletion method with collected cache keys..."
                local start_time=$(date +%s)

                # Delete each cache key
                IFS=',' read -ra KEYS <<< "$stored_keys"
                local attempted=0
                for cache_key in "${KEYS[@]}"; do
                    if [ -n "$cache_key" ]; then
                        ((attempted++))
                        if delete_by_cache_key "$cache_key"; then
                            ((removed++))
                        fi
                    fi
                done

                local end_time=$(date +%s)
                local elapsed=$((end_time - start_time))
                log "O(1) deletion complete in ${elapsed}s: attempted $attempted, removed $removed files"

                # If we didn't find any files via O(1), fall back to O(N) scan
                if [ "$removed" -eq 0 ]; then
                    log "WARNING: O(1) deletion found no files - falling back to O(N) scan"
                    removed=$(search_and_delete_cache_files "$uri")
                fi
            else
                # No cache keys available, use O(N) scan method
                log "No cache keys available - using O(N) scan method"
                log "NOTE: To enable O(1) deletion, ensure nginx logs include \$upstream_cache_key"

                removed=$(search_and_delete_cache_files "$uri")
            fi

            log "Remediation complete: removed $removed cache files for: $uri"

            # Suggest nginx reload if files were actually removed
            if [ "$removed" -gt 0 ]; then
                log "NOTE: Consider reloading nginx to clear internal cache metadata"
            fi
        fi

        # Reset state after remediation
        rm -f "$state_file"
    fi
}

# Clean up old state files (issues that resolved themselves)
cleanup_old_state() {
    # Remove state files older than 1 hour
    local cleaned=$(find "$STATE_DIR" -type f -mmin +60 -delete -print 2>/dev/null | wc -l)
    if [ "$cleaned" -gt 0 ]; then
        log "Cleaned up $cleaned old state files"
    fi
}

# Main daemon loop
main() {
    log "════════════════════════════════════════════════════════════════════"
    log "LANCACHE HEALTH DAEMON STARTING"
    log "════════════════════════════════════════════════════════════════════"
    log ""
    log "Configuration:"
    log "  LOG_FILE:          $LOG_FILE"
    log "  CACHE_DIR:         $CACHE_DIR"
    log "  STATE_DIR:         $STATE_DIR"
    log "  ERROR_THRESHOLD:   $ERROR_THRESHOLD"
    log "  CONFIRM_THRESHOLD: $CONFIRM_THRESHOLD"
    log "  CHECK_INTERVAL:    ${CHECK_INTERVAL}s"
    log "  MAX_SCAN_FILES:    $MAX_SCAN_FILES"
    log "  PARALLEL_JOBS:     $PARALLEL_JOBS"
    log "  DRY_RUN:           $DRY_RUN"
    log ""

    if [ "$DRY_RUN" == "true" ]; then
        log "⚠️  DRY RUN MODE - No files will be deleted"
        log "   Set DRY_RUN=false to enable automatic deletion"
    else
        log "⚠️  LIVE MODE - Cache files WILL be deleted automatically"
        log "   I/O throttling enabled (ionice -c2 -n7, nice -n15)"
    fi
    log ""

    # Check prerequisites
    if [ ! -f "$LOG_FILE" ]; then
        log_error "Log file not found: $LOG_FILE"
        log "Waiting for log file to appear..."
    fi

    if [ ! -d "$CACHE_DIR" ]; then
        log_error "Cache directory not found: $CACHE_DIR"
        exit 1
    fi

    # Count total cache files for context
    local total_cache=$(find "$CACHE_DIR" -type f 2>/dev/null | wc -l)
    log "Total cache files at startup: $total_cache"
    if [ "$total_cache" -gt "$MAX_SCAN_FILES" ]; then
        log "NOTE: Cache exceeds MAX_SCAN_FILES limit - scans will be limited"
    fi
    log ""

    # Main loop
    while true; do
        log "────────────────────────────────────────────────────────────────────"
        log "Starting health check cycle..."
        local cycle_start=$(date +%s)

        if [ -f "$LOG_FILE" ]; then
            local suspect_count=0

            # Analyze logs and get problematic URIs with cache keys
            # Output format: uri \t error_count \t error_type \t cache_keys
            while IFS=$'\t' read -r uri error_count error_type cache_keys; do
                if [ -n "$uri" ]; then
                    ((suspect_count++))
                    check_and_remediate "$uri" "$error_count" "$error_type" "$cache_keys"
                fi
            done < <(analyze_logs)

            if [ "$suspect_count" -eq 0 ]; then
                log "✓ No suspect URIs detected in this cycle"
            else
                log "Processed $suspect_count suspect URI(s)"
            fi

            cleanup_old_state
        else
            log "Log file not yet available, skipping analysis"
        fi

        local cycle_end=$(date +%s)
        local cycle_time=$((cycle_end - cycle_start))
        log "Health check complete in ${cycle_time}s. Sleeping ${CHECK_INTERVAL}s..."
        sleep "$CHECK_INTERVAL"
    done
}

# Handle signals gracefully
trap 'log "Received shutdown signal, exiting..."; exit 0' SIGTERM SIGINT

# Run main
main "$@"

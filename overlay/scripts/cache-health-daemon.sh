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
    # Looking for:
    # 1. Upstream 5xx errors with MISS (might have cached bad response)
    # 2. Zero-byte responses
    # 3. STALE responses (background update might be failing)

    awk -v threshold="$ERROR_THRESHOLD" '
    {
        # Extract URI from request field
        if(match($0, /"(GET|HEAD|POST) ([^"]+)"/, arr)) {
            uri = arr[2]
            # Remove query string for grouping
            gsub(/\?.*$/, "", uri)
        } else {
            next
        }

        # Check for error conditions
        is_error = 0

        # Upstream 5xx error
        if($0 ~ /"50[0-9]"[[:space:]]*[0-9]/) {
            is_error = 1
            error_type[uri] = "upstream_5xx"
        }

        # Zero-byte response on MISS
        if($0 ~ /"MISS"/ && $0 ~ / 0 "/) {
            is_error = 1
            error_type[uri] = "zero_bytes"
        }

        if(is_error) {
            errors[uri]++
        }
    }
    END {
        for(uri in errors) {
            if(errors[uri] >= threshold) {
                print uri "\t" errors[uri] "\t" error_type[uri]
            }
        }
    }
    ' "$LOG_FILE" 2>/dev/null
}

# Optimized cache file search using parallel processing
search_and_delete_cache_files() {
    local uri="$1"
    local start_time=$(date +%s)

    # Use parallel search with xargs
    local removed=0
    local scanned=0

    log "Searching cache (max $MAX_SCAN_FILES files with $PARALLEL_JOBS workers)..."

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

    return $removed
}

# Check if URI should be remediated
check_and_remediate() {
    local uri="$1"
    local error_count="$2"
    local error_type="$3"

    local state_file=$(uri_to_statefile "$uri")

    # Read or initialize confirmation count
    local confirm_count=0
    if [ -f "$state_file" ]; then
        confirm_count=$(cat "$state_file" 2>/dev/null || echo "0")
    fi
    ((confirm_count++))

    # Save state
    echo "$confirm_count" > "$state_file"

    log "SUSPECT: $uri (errors: $error_count, type: $error_type, confirmations: $confirm_count/$CONFIRM_THRESHOLD)"

    # Check if we've reached confirmation threshold
    if [ "$confirm_count" -ge "$CONFIRM_THRESHOLD" ]; then
        log "CONFIRMED BAD: $uri - initiating remediation"

        if [ "$DRY_RUN" == "true" ]; then
            log "DRY RUN: Would search and delete cache files for: $uri"

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
        else
            log "Searching for cache files matching: $uri"

            search_and_delete_cache_files "$uri"
            local removed=$?

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

            # Analyze logs and get problematic URIs
            while IFS=$'\t' read -r uri error_count error_type; do
                if [ -n "$uri" ]; then
                    ((suspect_count++))
                    check_and_remediate "$uri" "$error_count" "$error_type"
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

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

set -e

LOG_FILE="${LOG_FILE:-/data/logs/access.log}"
CACHE_DIR="${CACHE_DIR:-/data/cache/cache}"
STATE_DIR="${STATE_DIR:-/data/cache/.health-state}"
ERROR_THRESHOLD="${ERROR_THRESHOLD:-5}"
CONFIRM_THRESHOLD="${CONFIRM_THRESHOLD:-3}"
CHECK_INTERVAL="${CHECK_INTERVAL:-300}"
DRY_RUN="${DRY_RUN:-true}"
DAEMON_LOG="${DAEMON_LOG:-/data/logs/cache-health-daemon.log}"

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

            # Still do the search to show what would happen
            local count=$(find "$CACHE_DIR" -type f -exec sh -c 'head -c 2000 "$1" 2>/dev/null | head -3 | grep -q "$2" && echo found' _ {} "$uri" \; 2>/dev/null | wc -l)
            log "DRY RUN: Would delete approximately $count cache files"
        else
            log "Searching for cache files matching: $uri"

            local removed=0
            while IFS= read -r file; do
                if head -c 2000 "$file" 2>/dev/null | head -3 | grep -q "$uri"; then
                    if rm -f "$file" 2>/dev/null; then
                        ((removed++))
                        log "REMOVED: $file"
                    else
                        log_error "Failed to remove: $file"
                    fi
                fi
            done < <(find "$CACHE_DIR" -type f 2>/dev/null)

            log "Remediation complete: removed $removed cache files for: $uri"
        fi

        # Reset state after remediation
        rm -f "$state_file"
    fi
}

# Clean up old state files (issues that resolved themselves)
cleanup_old_state() {
    # Remove state files older than 1 hour
    find "$STATE_DIR" -type f -mmin +60 -delete 2>/dev/null || true
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
    log "  DRY_RUN:           $DRY_RUN"
    log ""

    if [ "$DRY_RUN" == "true" ]; then
        log "⚠️  DRY RUN MODE - No files will be deleted"
        log "   Set DRY_RUN=false to enable automatic deletion"
    else
        log "⚠️  LIVE MODE - Cache files WILL be deleted automatically"
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

    # Main loop
    while true; do
        log "────────────────────────────────────────────────────────────────────"
        log "Starting health check cycle..."

        if [ -f "$LOG_FILE" ]; then
            # Analyze logs and get problematic URIs
            while IFS=$'\t' read -r uri error_count error_type; do
                if [ -n "$uri" ]; then
                    check_and_remediate "$uri" "$error_count" "$error_type"
                fi
            done < <(analyze_logs)

            cleanup_old_state
        else
            log "Log file not yet available, skipping analysis"
        fi

        log "Health check complete. Sleeping ${CHECK_INTERVAL}s..."
        sleep "$CHECK_INTERVAL"
    done
}

# Handle signals gracefully
trap 'log "Received shutdown signal, exiting..."; exit 0' SIGTERM SIGINT

# Run main
main "$@"

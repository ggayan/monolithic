#!/bin/bash
# Find and optionally delete nginx cache files matching a URI pattern
# Optimized with parallel processing for large cache directories
#
# Usage: find-cache-file.sh <uri-pattern> [--delete] [--dry-run]
# Examples:
#   find-cache-file.sh '/depot/123/chunk'           # Find matching cache files
#   find-cache-file.sh '/depot/123/chunk' --delete  # Find and delete
#   find-cache-file.sh '/game/update.zip' --dry-run # Show what would be deleted

set -eo pipefail

CACHE_DIR="${CACHE_DIR:-/data/cache/cache}"
PATTERN="$1"
ACTION="${2:-}"
DRY_RUN=false

# Performance tuning variables
PARALLEL_JOBS="${PARALLEL_JOBS:-$(nproc)}"  # Number of parallel search workers
MAX_FILES="${MAX_FILES:-0}"                 # Max files to scan (0 = unlimited)
BATCH_SIZE="${BATCH_SIZE:-100}"             # Files per parallel batch
IO_NICE="${IO_NICE:-true}"                  # Use ionice/nice for I/O throttling

if [ "$ACTION" == "--dry-run" ] || [ "$3" == "--dry-run" ]; then
    DRY_RUN=true
fi

show_usage() {
    echo "Usage: $0 <uri-pattern> [--delete] [--dry-run]"
    echo ""
    echo "Find nginx cache files matching a URI pattern."
    echo "The pattern is searched in cache file headers (first 2-3 lines contain the cache key)."
    echo ""
    echo "Options:"
    echo "  --delete   Delete matching cache files"
    echo "  --dry-run  Show what would be deleted without actually deleting"
    echo ""
    echo "Examples:"
    echo "  $0 '/depot/123/chunk/abc'              # Find cache files for this URI"
    echo "  $0 '/depot/123/chunk/abc' --delete     # Find and delete"
    echo "  $0 '/origin/game/' --dry-run           # Preview deletion"
    echo ""
    echo "Environment variables:"
    echo "  CACHE_DIR      Cache directory (default: /data/cache/cache)"
    echo "  PARALLEL_JOBS  Number of parallel workers (default: CPU count)"
    echo "  MAX_FILES      Maximum files to scan, 0=unlimited (default: 0)"
    echo "  BATCH_SIZE     Files processed per batch (default: 100)"
    echo "  IO_NICE        Use I/O throttling ionice/nice (default: true)"
    echo ""
    echo "Note: This searches the cache key in file headers, which is much faster"
    echo "than searching the entire file content."
    exit 1
}

if [ -z "$PATTERN" ]; then
    show_usage
fi

if [ ! -d "$CACHE_DIR" ]; then
    echo "Error: Cache directory not found: $CACHE_DIR"
    exit 1
fi

echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║           LANCACHE CACHE FILE FINDER (Parallel)                  ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo ""
echo "Cache directory: $CACHE_DIR"
echo "Search pattern:  $PATTERN"
echo "Action:          ${ACTION:-search only}"
echo "Parallel workers: $PARALLEL_JOBS"
if [ "$MAX_FILES" -gt 0 ]; then
    echo "Max files:       $MAX_FILES (limited scan)"
fi
if [ "$DRY_RUN" == "true" ]; then
    echo "Mode:            DRY RUN (no files will be deleted)"
fi
if [ "$IO_NICE" == "true" ]; then
    echo "I/O throttling:  ENABLED (reduced system impact)"
fi
echo ""

# Count total files (with optional limit)
echo "Counting cache files..."
if [ "$MAX_FILES" -gt 0 ]; then
    total_files=$(find "$CACHE_DIR" -type f 2>/dev/null | head -n "$MAX_FILES" | wc -l)
    echo "Total cache files: $total_files (limited to MAX_FILES=$MAX_FILES)"
else
    total_files=$(find "$CACHE_DIR" -type f 2>/dev/null | wc -l)
    echo "Total cache files: $total_files"
fi
echo ""

if [ "$total_files" -eq 0 ]; then
    echo "No cache files found."
    exit 0
fi

echo "Searching for pattern: $PATTERN"
echo "Using parallel search with $PARALLEL_JOBS workers..."
echo ""

# Temporary file for collecting results
RESULTS_FILE=$(mktemp)
trap "rm -f '$RESULTS_FILE'" EXIT

# Worker function to search a batch of files
# This is exported and run by xargs in parallel
search_worker() {
    local pattern="$1"
    shift

    for file in "$@"; do
        # Check first 2KB of file (contains cache key header)
        if head -c 2000 "$file" 2>/dev/null | head -3 | grep -qF "$pattern"; then
            # Output just the filename for main process to handle
            echo "$file"
        fi
    done
}
export -f search_worker

# Build the command prefix with I/O throttling if enabled
CMD_PREFIX=""
if [ "$IO_NICE" == "true" ]; then
    # Use ionice (best effort, lowest priority) and nice if available
    if command -v ionice >/dev/null 2>&1; then
        CMD_PREFIX="ionice -c2 -n7 "
    fi
    if command -v nice >/dev/null 2>&1; then
        CMD_PREFIX="${CMD_PREFIX}nice -n15 "
    fi
fi

# Parallel search using xargs
# Process files in batches to reduce overhead
echo "Scanning cache files..."

# Apply I/O throttling to entire pipeline (find + xargs)
# This ensures even directory traversal is throttled
if [ "$MAX_FILES" -gt 0 ]; then
    $CMD_PREFIX sh -c "
        find '$CACHE_DIR' -type f 2>/dev/null | head -n $MAX_FILES | \
        xargs -P $PARALLEL_JOBS -n $BATCH_SIZE bash -c \
            'search_worker \"\$@\"' _ '$PATTERN'
    " > "$RESULTS_FILE"
else
    $CMD_PREFIX sh -c "
        find '$CACHE_DIR' -type f 2>/dev/null | \
        xargs -P $PARALLEL_JOBS -n $BATCH_SIZE bash -c \
            'search_worker \"\$@\"' _ '$PATTERN'
    " > "$RESULTS_FILE"
fi

# Read results
mapfile -t found_files < "$RESULTS_FILE"
found_count="${#found_files[@]}"

echo ""
echo "════════════════════════════════════════════════════════════════════"
echo "SEARCH COMPLETE"
echo "════════════════════════════════════════════════════════════════════"
echo ""
echo "Files checked: $total_files"
echo "Matches found: $found_count"
echo ""

if [ "$found_count" -eq 0 ]; then
    echo "No matching cache files found."
    exit 0
fi

# Show found files with their cache keys
echo "Found cache files:"
echo "────────────────────────────────────────────────────────────────────"
for file in "${found_files[@]}"; do
    echo "FOUND: $file"

    # Show cache key from file header
    echo "Cache key:"
    head -3 "$file" 2>/dev/null | sed 's/^/  /' || echo "  (unable to read)"
    echo ""
done

# Handle deletion
if [ "$ACTION" == "--delete" ]; then
    echo ""

    if [ "$DRY_RUN" == "true" ]; then
        echo "DRY RUN - Would delete $found_count files:"
        for file in "${found_files[@]}"; do
            echo "  [DRY RUN] Would delete: $file"
        done
    else
        echo "Deleting $found_count files..."
        deleted=0
        failed=0

        for file in "${found_files[@]}"; do
            if rm -f "$file" 2>/dev/null; then
                echo "  ✓ Deleted: $file"
                ((deleted++))
            else
                echo "  ✗ Failed to delete: $file"
                ((failed++))
            fi
        done

        echo ""
        echo "════════════════════════════════════════════════════════════════════"
        echo "Successfully deleted: $deleted files"
        if [ "$failed" -gt 0 ]; then
            echo "Failed to delete:     $failed files"
        fi

        # Suggest nginx reload to clear internal cache state
        echo ""
        echo "Recommendation: Reload nginx to clear internal cache metadata:"
        echo "  nginx -s reload"
    fi
else
    echo "To delete these files, run:"
    echo "  $0 '$PATTERN' --delete"
    echo ""
    echo "To preview deletion:"
    echo "  $0 '$PATTERN' --delete --dry-run"
fi

echo ""

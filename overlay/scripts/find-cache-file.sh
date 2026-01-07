#!/bin/bash
# Find and optionally delete nginx cache files matching a URI pattern
# Much faster than the traditional awk-based approach for targeted searches
#
# Usage: find-cache-file.sh <uri-pattern> [--delete] [--dry-run]
# Examples:
#   find-cache-file.sh '/depot/123/chunk'           # Find matching cache files
#   find-cache-file.sh '/depot/123/chunk' --delete  # Find and delete
#   find-cache-file.sh '/game/update.zip' --dry-run # Show what would be deleted

set -e

CACHE_DIR="${CACHE_DIR:-/data/cache/cache}"
PATTERN="$1"
ACTION="${2:-}"
DRY_RUN=false

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
    echo "  CACHE_DIR  Cache directory (default: /data/cache/cache)"
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
echo "║           LANCACHE CACHE FILE FINDER                             ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo ""
echo "Cache directory: $CACHE_DIR"
echo "Search pattern:  $PATTERN"
echo "Action:          ${ACTION:-search only}"
if [ "$DRY_RUN" == "true" ]; then
    echo "Mode:            DRY RUN (no files will be deleted)"
fi
echo ""

# Count total files
echo "Counting cache files..."
total_files=$(find "$CACHE_DIR" -type f 2>/dev/null | wc -l)
echo "Total cache files: $total_files"
echo ""

if [ "$total_files" -eq 0 ]; then
    echo "No cache files found."
    exit 0
fi

echo "Searching for pattern: $PATTERN"
echo "This may take a while for large caches..."
echo ""

# Find matching files
# nginx cache files have the cache key in the first few lines
found_files=()
checked=0
found=0

# Use a more efficient approach with xargs and head
while IFS= read -r file; do
    ((checked++))

    # Show progress every 10000 files
    if ((checked % 10000 == 0)); then
        echo "Progress: $checked / $total_files files checked, $found matches found..."
    fi

    # Check first 3 lines of file for pattern (cache key is in header)
    # Using head -c 2000 to limit read size for efficiency
    if head -c 2000 "$file" 2>/dev/null | head -3 | grep -q "$PATTERN"; then
        found_files+=("$file")
        ((found++))

        echo "────────────────────────────────────────────────────────────────────"
        echo "FOUND: $file"

        # Show cache key from file header
        echo "Cache key:"
        head -3 "$file" 2>/dev/null | sed 's/^/  /'
        echo ""
    fi
done < <(find "$CACHE_DIR" -type f 2>/dev/null)

echo ""
echo "════════════════════════════════════════════════════════════════════"
echo "SEARCH COMPLETE"
echo "════════════════════════════════════════════════════════════════════"
echo ""
echo "Files checked: $checked"
echo "Matches found: ${#found_files[@]}"
echo ""

if [ "${#found_files[@]}" -eq 0 ]; then
    echo "No matching cache files found."
    exit 0
fi

# Handle deletion
if [ "$ACTION" == "--delete" ]; then
    echo ""

    if [ "$DRY_RUN" == "true" ]; then
        echo "DRY RUN - Would delete ${#found_files[@]} files:"
        for file in "${found_files[@]}"; do
            echo "  [DRY RUN] Would delete: $file"
        done
    else
        echo "Deleting ${#found_files[@]} files..."
        deleted=0
        for file in "${found_files[@]}"; do
            if rm -f "$file" 2>/dev/null; then
                echo "  Deleted: $file"
                ((deleted++))
            else
                echo "  Failed to delete: $file"
            fi
        done
        echo ""
        echo "Successfully deleted: $deleted files"
    fi
else
    echo "To delete these files, run:"
    echo "  $0 '$PATTERN' --delete"
    echo ""
    echo "To preview deletion:"
    echo "  $0 '$PATTERN' --delete --dry-run"
fi

echo ""

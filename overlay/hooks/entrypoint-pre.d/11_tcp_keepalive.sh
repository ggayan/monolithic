#!/bin/bash
# Configure TCP keepalive settings for faster dead connection detection
#
# These settings are REQUIRED for proxy_socket_keepalive to be effective.
# Without tuning, the default tcp_keepalive_time is 7200 seconds (2 hours),
# making dead connection detection extremely slow.
#
# With these settings, dead connections are detected in ~2 minutes instead of 2+ hours.

set -e

# Recommended values from PLAN.md
KEEPALIVE_TIME=${TCP_KEEPALIVE_TIME:-60}      # Time before first probe (default: 7200s)
KEEPALIVE_INTVL=${TCP_KEEPALIVE_INTVL:-10}    # Interval between probes (default: 75s)
KEEPALIVE_PROBES=${TCP_KEEPALIVE_PROBES:-6}   # Failed probes before declaring dead (default: 9)

# Detection timeline with these settings:
# - First probe at: 60 seconds
# - Subsequent probes every: 10 seconds
# - Total time to detect dead connection: 60 + (6 * 10) = 120 seconds (~2 minutes)

apply_sysctl() {
    local key="$1"
    local value="$2"
    local current

    # Get current value
    current=$(sysctl -n "$key" 2>/dev/null || echo "unknown")

    if [ "$current" = "$value" ]; then
        echo "  $key = $value (already set)"
        return 0
    fi

    # Try to set the value
    if sysctl -w "$key=$value" >/dev/null 2>&1; then
        echo "  $key = $value (was: $current)"
        return 0
    else
        echo "  WARNING: Cannot set $key (current: $current, wanted: $value)"
        echo "           Container may need --privileged or CAP_NET_ADMIN capability"
        return 1
    fi
}

echo "Configuring TCP keepalive settings for proxy_socket_keepalive..."

# Track if any settings failed
failed=0

apply_sysctl "net.ipv4.tcp_keepalive_time" "$KEEPALIVE_TIME" || failed=1
apply_sysctl "net.ipv4.tcp_keepalive_intvl" "$KEEPALIVE_INTVL" || failed=1
apply_sysctl "net.ipv4.tcp_keepalive_probes" "$KEEPALIVE_PROBES" || failed=1

if [ "$failed" -eq 1 ]; then
    echo ""
    echo "NOTE: Some TCP keepalive settings could not be applied."
    echo "      proxy_socket_keepalive will still work, but dead connection"
    echo "      detection may take longer than optimal (up to 2+ hours with defaults)."
    echo ""
    echo "      To fix, run the container with: --cap-add=NET_ADMIN"
    echo "      Or set sysctl on the host:"
    echo "        sysctl -w net.ipv4.tcp_keepalive_time=$KEEPALIVE_TIME"
    echo "        sysctl -w net.ipv4.tcp_keepalive_intvl=$KEEPALIVE_INTVL"
    echo "        sysctl -w net.ipv4.tcp_keepalive_probes=$KEEPALIVE_PROBES"
    echo ""
else
    echo "TCP keepalive configured: dead connections detected in ~$((KEEPALIVE_TIME + KEEPALIVE_PROBES * KEEPALIVE_INTVL)) seconds"
fi

# Don't fail container startup if sysctl cannot be set
# The container will still work, just with slower dead connection detection
exit 0

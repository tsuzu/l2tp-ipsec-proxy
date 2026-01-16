#!/bin/bash

set -e

# Check required environment variables
if [ -z "$VPN_SERVER_IP" ]; then
    echo "Error: VPN_SERVER_IP is not set"
    exit 1
fi

if [ -z "$PSK" ]; then
    echo "Error: PSK is not set"
    exit 1
fi

if [ -z "$USER" ]; then
    echo "Error: USER is not set"
    exit 1
fi

if [ -z "$PASS" ]; then
    echo "Error: PASS is not set"
    exit 1
fi

# Set default RIGHTID if not specified
if [ -z "$RIGHTID" ]; then
    echo "Warning: RIGHTID is not set, using VPN_SERVER_IP as default"
    RIGHTID=$VPN_SERVER_IP
fi

# Set default MTU if not specified
if [ -z "$MTU" ]; then
    MTU=1410
fi

# Set default MRU if not specified
if [ -z "$MRU" ]; then
    MRU=1410
fi

# Set default GOST ports if not specified
if [ -z "$GOST_HTTP_PORT" ]; then
    GOST_HTTP_PORT=8080
fi

if [ -z "$GOST_SOCKS_PORT" ]; then
    GOST_SOCKS_PORT=1080
fi

# BYPASS_CIDRS is optional (comma-separated list of CIDRs)
# Example: BYPASS_CIDRS="10.0.0.0/8,172.16.0.0/12,192.168.0.0/16"

# Set debug log settings
if [ -z "$DEBUG_LOGS" ]; then
    DEBUG_LOGS="false"
fi

# Configure debug settings based on DEBUG_LOGS
if [ "$DEBUG_LOGS" = "true" ]; then
    CHARONDEBUG="all"
    XL2TPD_DEBUG="yes"
    PPP_DEBUG="debug"
else
    CHARONDEBUG=""
    XL2TPD_DEBUG="no"
    PPP_DEBUG="# debug disabled"
fi

echo "Configuring VPN connection..."
echo "Server: $VPN_SERVER_IP"
echo "Right ID: $RIGHTID"
echo "User: $USER"
echo "MTU: $MTU"
echo "MRU: $MRU"

# Generate ipsec.conf
sed -e "s/VPN_SERVER_IP_PLACEHOLDER/$VPN_SERVER_IP/g" \
    -e "s/RIGHTID_PLACEHOLDER/$RIGHTID/g" \
    -e "s/CHARONDEBUG_PLACEHOLDER/$CHARONDEBUG/g" \
    /etc/ipsec.conf.template > /etc/ipsec.conf

# Generate ipsec.secrets
sed -e "s/VPN_SERVER_IP_PLACEHOLDER/$VPN_SERVER_IP/g" \
    -e "s/PSK_PLACEHOLDER/$PSK/g" \
    /etc/ipsec.secrets.template > /etc/ipsec.secrets

# Set proper permissions
chmod 600 /etc/ipsec.secrets

# Generate xl2tpd.conf
sed -e "s/VPN_SERVER_IP_PLACEHOLDER/$VPN_SERVER_IP/g" \
    -e "s/XL2TPD_DEBUG_PLACEHOLDER/$XL2TPD_DEBUG/g" \
    /etc/xl2tpd/xl2tpd.conf.template > /etc/xl2tpd/xl2tpd.conf

# Generate PPP options
sed -e "s/VPN_SERVER_IP_PLACEHOLDER/$VPN_SERVER_IP/g" \
    -e "s/USER_PLACEHOLDER/$USER/g" \
    -e "s/PASS_PLACEHOLDER/$PASS/g" \
    -e "s/MTU_PLACEHOLDER/$MTU/g" \
    -e "s/MRU_PLACEHOLDER/$MRU/g" \
    -e "s/PPP_DEBUG_PLACEHOLDER/$PPP_DEBUG/g" \
    /etc/ppp/options.l2tpd.client.template > /etc/ppp/options.l2tpd.client

# Create log file
touch /var/log/xl2tpd.log

rm /var/run/starter.charon.pid || true

echo "Starting IPSec..."
ipsec start --nofork &
IPSEC_PID=$!

# Wait for IPSec to initialize
sleep 3

# Check if IPSec is running
if ! kill -0 $IPSEC_PID 2>/dev/null; then
    echo "Error: IPSec failed to start"
    exit 1
fi

echo "IPSec started successfully"

# Wait for IPSec connection to establish
echo "Waiting for IPSec connection..."
MAX_WAIT=30
COUNTER=0
while [ $COUNTER -lt $MAX_WAIT ]; do
    if ipsec status | grep -q "ESTABLISHED"; then
        echo "IPSec connection established"
        break
    fi
    sleep 1
    COUNTER=$((COUNTER + 1))
done

if [ $COUNTER -eq $MAX_WAIT ]; then
    echo "Error: IPSec connection timeout"
    ipsec status
    exit 1
fi

# Get the current default route information before starting xl2tpd
# This needs to be done BEFORE xl2tpd/pppd replaces the default route
DEFAULT_ROUTE=$(ip route show default | head -n 1)
DEFAULT_GW=$(echo "$DEFAULT_ROUTE" | awk '{for(i=1;i<=NF;i++){if($i=="via"){print $(i+1)}}}')
DEFAULT_DEV=$(echo "$DEFAULT_ROUTE" | awk '{for(i=1;i<=NF;i++){if($i=="dev"){print $(i+1)}}}')

echo "Current default route: $DEFAULT_ROUTE"
echo "Default gateway: $DEFAULT_GW"
echo "Default device: $DEFAULT_DEV"

# Add explicit route to VPN server via the current default route to preserve connectivity
# This must be done BEFORE xl2tpd starts, as pppd will replace the default route
if [ -n "$DEFAULT_GW" ] && [ -n "$DEFAULT_DEV" ]; then
    echo "Adding explicit route to VPN server via $DEFAULT_GW dev $DEFAULT_DEV..."
    ip route add $VPN_SERVER_IP via $DEFAULT_GW dev $DEFAULT_DEV 2>/dev/null || true
elif [ -n "$DEFAULT_DEV" ]; then
    echo "Adding explicit route to VPN server via dev $DEFAULT_DEV (no gateway)..."
    ip route add $VPN_SERVER_IP dev $DEFAULT_DEV 2>/dev/null || true
else
    echo "Warning: Could not determine default route, VPN connection may be unstable"
fi

echo "Route to VPN server: $(ip route get $VPN_SERVER_IP)"

echo "Starting xl2tpd..."
xl2tpd -D -c /etc/xl2tpd/xl2tpd.conf &
XL2TPD_PID=$!

# Wait for xl2tpd to initialize
sleep 2

# Check if xl2tpd is running
if ! kill -0 $XL2TPD_PID 2>/dev/null; then
    echo "Error: xl2tpd failed to start"
    exit 1
fi

echo "xl2tpd started successfully"

# Connect to L2TP
echo "Connecting to L2TP..."
echo "c vpn-connection" > /var/run/xl2tpd/l2tp-control

# Wait for PPP interface
echo "Waiting for ppp0 interface..."
MAX_WAIT=30
COUNTER=0
while [ $COUNTER -lt $MAX_WAIT ]; do
    if ip addr show ppp0 >/dev/null 2>&1; then
        echo "ppp0 interface is up"
        ip addr show ppp0
        break
    fi
    sleep 1
    COUNTER=$((COUNTER + 1))
done

if [ $COUNTER -eq $MAX_WAIT ]; then
    echo "Error: ppp0 interface timeout"
    cat /var/log/xl2tpd.log
    exit 1
fi

echo "Route to VPN server: $(ip route get $VPN_SERVER_IP)"
echo "Current routing table:"
ip route

# Add bypass routes for specified CIDRs
if [ -n "$BYPASS_CIDRS" ]; then
    echo "Adding bypass routes for CIDRs: $BYPASS_CIDRS"
    IFS=',' read -ra CIDR_ARRAY <<< "$BYPASS_CIDRS"
    for CIDR in "${CIDR_ARRAY[@]}"; do
        # Trim whitespace
        CIDR=$(echo "$CIDR" | xargs)
        if [ -n "$CIDR" ]; then
            if [ -n "$DEFAULT_GW" ] && [ -n "$DEFAULT_DEV" ]; then
                echo "  Adding route: $CIDR via $DEFAULT_GW dev $DEFAULT_DEV"
                ip route add "$CIDR" via "$DEFAULT_GW" dev "$DEFAULT_DEV" 2>/dev/null || echo "    (route already exists or failed)"
            elif [ -n "$DEFAULT_DEV" ]; then
                echo "  Adding route: $CIDR dev $DEFAULT_DEV"
                ip route add "$CIDR" dev "$DEFAULT_DEV" 2>/dev/null || echo "    (route already exists or failed)"
            fi
        fi
    done
    echo "Bypass routes added."
fi

echo "Current routing table after bypass routes:"
ip route

# Enable MSS clamping for TCP connections over ppp0
# This prevents packet fragmentation issues with IPSec
echo "Configuring MSS clamping for ppp0..."
iptables -t mangle -A FORWARD -o ppp0 -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
iptables -t mangle -A OUTPUT -o ppp0 -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
echo "MSS clamping configured"

# Start gost proxy server
echo "Starting gost proxy server..."
echo "  HTTP proxy: 0.0.0.0:$GOST_HTTP_PORT"
echo "  SOCKS5 proxy: 0.0.0.0:$GOST_SOCKS_PORT"

gost -L "http://:$GOST_HTTP_PORT" -L "socks5://:$GOST_SOCKS_PORT" &
GOST_PID=$!

# Wait for gost to initialize
sleep 2

# Check if gost is running
if ! kill -0 $GOST_PID 2>/dev/null; then
    echo "Warning: gost failed to start, but continuing with VPN connection"
    GOST_PID=""
else
    echo "gost started successfully (PID: $GOST_PID)"
fi

echo "VPN connection established successfully!"
echo "Keeping connection alive..."

# Monitor processes and keep container running
while true; do
    if ! kill -0 $IPSEC_PID 2>/dev/null; then
        echo "Error: IPSec process died"
        exit 1
    fi

    if ! kill -0 $XL2TPD_PID 2>/dev/null; then
        echo "Error: xl2tpd process died"
        exit 1
    fi

    if ! ip addr show ppp0 >/dev/null 2>&1; then
        echo "Error: ppp0 interface is down"
        exit 1
    fi

    # Monitor gost if it was started successfully
    if [ -n "$GOST_PID" ] && ! kill -0 $GOST_PID 2>/dev/null; then
        echo "Warning: gost process died, restarting..."
        gost -L "http://:$GOST_HTTP_PORT" -L "socks5://:$GOST_SOCKS_PORT" &
        GOST_PID=$!
        sleep 2
        if ! kill -0 $GOST_PID 2>/dev/null; then
            echo "Error: Failed to restart gost"
            GOST_PID=""
        else
            echo "gost restarted successfully (PID: $GOST_PID)"
        fi
    fi

    sleep 5
done

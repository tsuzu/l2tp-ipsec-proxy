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

echo "Configuring VPN connection..."
echo "Server: $VPN_SERVER_IP"
echo "Right ID: $RIGHTID"
echo "User: $USER"
echo "MTU: $MTU"
echo "MRU: $MRU"

# Generate ipsec.conf
sed -e "s/VPN_SERVER_IP_PLACEHOLDER/$VPN_SERVER_IP/g" \
    -e "s/RIGHTID_PLACEHOLDER/$RIGHTID/g" \
    /etc/ipsec.conf.template > /etc/ipsec.conf

# Generate ipsec.secrets
sed -e "s/VPN_SERVER_IP_PLACEHOLDER/$VPN_SERVER_IP/g" \
    -e "s/PSK_PLACEHOLDER/$PSK/g" \
    /etc/ipsec.secrets.template > /etc/ipsec.secrets

# Set proper permissions
chmod 600 /etc/ipsec.secrets

# Generate xl2tpd.conf
sed -e "s/VPN_SERVER_IP_PLACEHOLDER/$VPN_SERVER_IP/g" \
    /etc/xl2tpd/xl2tpd.conf.template > /etc/xl2tpd/xl2tpd.conf

# Generate PPP options
sed -e "s/USER_PLACEHOLDER/$USER/g" \
    -e "s/PASS_PLACEHOLDER/$PASS/g" \
    -e "s/MTU_PLACEHOLDER/$MTU/g" \
    -e "s/MRU_PLACEHOLDER/$MRU/g" \
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

    sleep 5
done

FROM debian:bookworm-slim

ARG TARGETOS
ARG TARGETARCH
ARG GOST_VERSION=3.2.6

# Install required packages
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    strongswan \
    xl2tpd \
    ppp \
    bash \
    iproute2 \
    wget \
    ca-certificates \
    iptables && \
    rm -rf /var/lib/apt/lists/*

# Install go-gost with multi-architecture support
RUN ARCH=${TARGETARCH} && \
    if [ "$ARCH" = "amd64" ]; then ARCH="amd64"; \
    elif [ "$ARCH" = "arm64" ]; then ARCH="arm64"; \
    elif [ "$ARCH" = "arm" ]; then ARCH="armv7"; \
    else echo "Unsupported architecture: $ARCH" && exit 1; fi && \
    wget -O /tmp/gost.tar.gz "https://github.com/go-gost/gost/releases/download/v${GOST_VERSION}/gost_${GOST_VERSION}_${TARGETOS}_${ARCH}.tar.gz" && \
    tar -xzf /tmp/gost.tar.gz -C /usr/local/bin && \
    chmod +x /usr/local/bin/gost && \
    rm /tmp/gost.tar.gz

# Create necessary directories
RUN mkdir -p /var/run/xl2tpd

# Copy configuration templates
COPY ipsec.conf.template /etc/ipsec.conf.template
COPY ipsec.secrets.template /etc/ipsec.secrets.template
COPY xl2tpd.conf.template /etc/xl2tpd/xl2tpd.conf.template
COPY options.l2tpd.client.template /etc/ppp/options.l2tpd.client.template
COPY connect.sh /usr/local/bin/connect.sh

# Make connect script executable
RUN chmod +x /usr/local/bin/connect.sh

# Expose control file for xl2tpd
VOLUME /var/run/xl2tpd

ENTRYPOINT ["/usr/local/bin/connect.sh"]

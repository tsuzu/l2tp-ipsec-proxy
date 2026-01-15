FROM alpine:latest

# Install required packages
RUN apk add --no-cache \
    strongswan \
    xl2tpd \
    ppp \
    openrc \
    bash \
    iproute2

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

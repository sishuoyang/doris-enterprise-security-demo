FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && \
    apt-get install -y \
    krb5-kdc \
    krb5-admin-server \
    krb5-user \
    netcat-openbsd \
    net-tools \
    iproute2 \
    && rm -rf /var/lib/apt/lists/*

# Create directories
RUN mkdir -p /var/lib/krb5kdc /etc/krb5kdc

# Copy configuration
COPY krb5.conf /etc/krb5.conf

# Expose ports
EXPOSE 88 88/udp 749 464 464/udp

# Start script
COPY start-kdc.sh /usr/local/bin/start-kdc.sh
RUN chmod +x /usr/local/bin/start-kdc.sh

CMD ["/usr/local/bin/start-kdc.sh"]


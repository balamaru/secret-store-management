FROM ghcr.io/openbao/openbao-hsm:2.5.1

USER root

# Di Alpine, softhsm sudah include libsofthsm2.so
RUN apk add --no-cache \
    softhsm \
    opensc \
    && mkdir -p /var/lib/softhsm/tokens \
    && mkdir -p /etc/softhsm2 \
    && chmod 755 /var/lib/softhsm/tokens

# Buat softhsm2 config
RUN echo "directories.tokendir = /var/lib/softhsm/tokens" > /etc/softhsm2/softhsm2.conf \
    && echo "objectstore.backend = file" >> /etc/softhsm2/softhsm2.conf \
    && echo "log.level = INFO" >> /etc/softhsm2/softhsm2.conf

ENV SOFTHSM2_CONF=/etc/softhsm2/softhsm2.conf

# Verifikasi
RUN softhsm2-util --version \
    && find / -name "libsofthsm2.so" 2>/dev/null

USER openbao

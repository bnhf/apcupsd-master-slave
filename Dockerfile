#BUILD_DATE=$(date +%Y.%m.%d) && docker buildx build --platform linux/amd64,linux/arm64,linux/arm/v7 -f Dockerfile -t bnhf/apcupsd:latest -t bnhf/apcupsd:$BUILD_DATE --build-arg BUILD_DATE=$BUILD_DATE . --push --no-cache
FROM debian:13-slim
LABEL maintainer="Scott Ueland (https://github.com/bnhf)"

ARG BUILD_DATE
LABEL version="${BUILD_DATE}"

ENV LANG=C.UTF-8
ENV DEBIAN_FRONTEND=noninteractive
ENV APCUPSD_VERSION=${BUILD_DATE:-unknown}

RUN echo Starting. \
 && apt-get -q -y update \
 && apt-get -q -y install --no-install-recommends \
      apcupsd bash ca-certificates curl dbus iputils-ping jq \
      libapparmor1 libdbus-1-3 libexpat1 libsasl2-modules \
      mailutils postfix procps ssl-cert tzdata \
 && apt-get -q -y full-upgrade \
 && rm -rif /var/lib/apt/lists/* \
 && mkdir /opt/apcupsd \
 && mv /etc/apcupsd/* /opt/apcupsd \
 && echo Finished.

COPY scripts /opt/apcupsd
COPY postfix /etc/postfix
COPY start.sh /

CMD ["/start.sh"]

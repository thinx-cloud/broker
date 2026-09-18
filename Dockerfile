# Define Mosquitto version, see also .github/workflows/build_and_push_docker_images.yml for
# the automatically built images
ARG MOSQUITTO_VERSION=2.0.21
# Define libwebsocket version
ARG LWS_VERSION=4.3.3

# Docker Hardened Image base (CIS-compliant, DHI-maintained Debian 13 "trixie").
# Build stages take the `-dev` variant: it runs as root and ships apt plus a
# toolchain, neither of which the bare `:trixie` runtime variant has.
FROM dhi.io/debian-base:trixie-dev AS mosquitto_builder
ARG MOSQUITTO_VERSION
ARG LWS_VERSION

# Get mosquitto build dependencies.
RUN apt-get update && apt-get install -y --no-install-recommends wget build-essential cmake libssl-dev libcjson-dev ca-certificates gnupg2

# Get libwebsocket. Debian's libwebsockets is too old for Mosquitto version > 2.x so it gets built from source.
RUN set -ex; \
    wget https://github.com/warmcat/libwebsockets/archive/v${LWS_VERSION}.tar.gz -O /tmp/lws.tar.gz; \
    mkdir -p /build/lws; \
    tar --strip=1 -xf /tmp/lws.tar.gz -C /build/lws; \
    rm /tmp/lws.tar.gz; \
    cd /build/lws; \
    cmake . \
        -DCMAKE_BUILD_TYPE=MinSizeRel \
        -DCMAKE_INSTALL_PREFIX=/usr \
        -DLWS_IPV6=ON \
        -DLWS_WITHOUT_BUILTIN_GETIFADDRS=ON \
        -DLWS_WITHOUT_CLIENT=ON \
        -DLWS_WITHOUT_EXTENSIONS=ON \
        -DLWS_WITHOUT_TESTAPPS=ON \
        -DLWS_WITH_HTTP2=OFF \
        -DLWS_WITH_SHARED=OFF \
        -DLWS_WITH_ZIP_FOPS=OFF \
        -DLWS_WITH_ZLIB=OFF \
        -DLWS_WITH_EXTERNAL_POLL=ON; \
    make -j "$(nproc)"; \
    rm -rf /root/.cmake

WORKDIR /app

RUN mkdir -p mosquitto/auth mosquitto/conf.d

RUN wget http://mosquitto.org/files/source/mosquitto-${MOSQUITTO_VERSION}.tar.gz

RUN tar xzvf mosquitto-${MOSQUITTO_VERSION}.tar.gz

# Build mosquitto.
RUN set -ex; \
    cd mosquitto-${MOSQUITTO_VERSION}; \
    make CFLAGS="-Wall -O2 -I/build/lws/include" LDFLAGS="-L/build/lws/lib" WITH_WEBSOCKETS=yes; \
    make install

# Builder for the Mosquitto Go Auth plugin. The Go release is pinned rather than
# floating on golang:latest because it is what ends up recorded as the `stdlib`
# package in go-auth.so and pw, which is what syft/grype report against.
# GOTOOLCHAIN=local keeps that pin honest: without it, a dependency whose go.mod
# asks for a newer release makes Go silently download and build with that
# toolchain instead, changing the stdlib version in the shipped binaries.
FROM golang:1.26.6 AS go_auth_builder
ENV GOTOOLCHAIN=local

ENV CGO_CFLAGS="-I/usr/local/include -fPIC"
ENV CGO_LDFLAGS="-shared -Wl,-unresolved-symbols=ignore-all"
ENV CGO_ENABLED=1

# Bring TARGETPLATFORM to the build scope
ARG TARGETPLATFORM="linux/amd64"
ENV BUILDPLATFORM="linux/amd64"

# Install TARGETPLATFORM parser to translate its value to GOOS, GOARCH, and GOARM
COPY --from=tonistiigi/xx:golang / /
RUN go env

# Install needed libc and gcc for target platform.
RUN set -ex; \
  if [ ! -z "$TARGETPLATFORM" ]; then \
    case "$TARGETPLATFORM" in \
  "linux/arm64") \
    apt-get update && apt-get install -y gcc-aarch64-linux-gnu libc6-dev-arm64-cross \
    ;; \
  "linux/arm/v7") \
    apt-get update && apt-get install -y gcc-arm-linux-gnueabihf libc6-dev-armhf-cross \
    ;; \
  "linux/arm/v6") \
    apt-get update && apt-get install -y gcc-arm-linux-gnueabihf libc6-dev-armel-cross libc6-dev-armhf-cross \
    ;; \
  esac \
  fi

WORKDIR /app
COPY --from=mosquitto_builder /usr/local/include/ /usr/local/include/

COPY ./goauth ./
# Dependencies come from the committed go.mod/go.sum. This used to run
# `go get -u ./...` on every build, which floated every dependency to whatever
# was newest at build time -- unreproducible, and able to drag in a module
# requiring a newer toolchain than the one pinned above.
RUN set -ex; \
    go mod download; \
    go build -buildmode=c-archive go-auth.go; \
    go build -buildmode=c-shared -o go-auth.so; \
	  go build pw-gen/pw.go

# Stage the handful of runtime packages the hardened runtime image does not
# ship. `:trixie` has no package manager, so they are downloaded here and
# unpacked into a rootfs that the final stage copies in wholesale. `--reinstall`
# is needed because some of these are already present in the -dev variant and
# apt would otherwise skip the download. Everything lands in /usr/bin and
# /usr/lib/<triplet>, both of which ld.so searches by default -- `:trixie` has
# neither ldconfig nor an ld.so.cache.
FROM dhi.io/debian-base:trixie-dev AS runtime_deps
RUN set -ex; \
    apt-get update; \
    apt-get install -y --no-install-recommends --reinstall --download-only \
        libc-ares2 libcjson1 libuuid1 tini gettext-base; \
    mkdir -p /rootfs; \
    for deb in /var/cache/apt/archives/*.deb; do dpkg-deb -x "$deb" /rootfs; done; \
    rm -rf /rootfs/usr/share/doc /rootfs/usr/share/man /rootfs/usr/share/locale /rootfs/usr/share/lintian

#Start from a new image: the hardened runtime variant, which carries no package
# manager, no compiler and no shell utilities beyond a minimal userland.
# openssl and ca-certificates are already part of it; libssl-dev/libcjson-dev
# were only ever build-time dependencies and are dropped here.
FROM dhi.io/debian-base:trixie

COPY --from=runtime_deps /rootfs/ /

# `:trixie` defaults to USER 65532. Mosquitto is still started as root so that
# the `user mosquitto` directive in mosquitto.conf can drop privileges itself,
# which is how this image has always behaved. Running the container as 65532
# outright would additionally require the mounted /mqtt volumes to be owned by
# that uid, so it is left as a separate change.
USER 0

# No useradd/groupadd in the runtime variant, so the account is appended to the
# passwd/group databases directly. 1883 is the mosquitto port, used as the uid
# for recognisability; the previous image let adduser pick an arbitrary one.
RUN set -ex; \
    printf 'mosquitto:x:1883:\n' >> /etc/group; \
    printf 'mosquitto:x:1883:1883:mosquitto:/var/lib/mosquitto:/sbin/nologin\n' >> /etc/passwd; \
    mkdir -p /var/lib/mosquitto /var/log/mosquitto; \
    chown -R 1883:1883 /var/lib/mosquitto /var/log/mosquitto

#Copy confs, plugin so and mosquitto binary.
COPY --from=mosquitto_builder /app/mosquitto/ /mosquitto/
COPY --from=go_auth_builder /app/pw /mosquitto/pw
COPY --from=go_auth_builder /app/go-auth.so /mosquitto/go-auth.so
COPY --from=mosquitto_builder /usr/local/sbin/mosquitto /usr/sbin/mosquitto

# /usr/local/lib is not on ld.so's default search path, and the runtime variant
# has neither ldconfig nor an ld.so.cache to put it there, so libmosquitto goes
# straight into /usr/lib -- a directory ld.so searches on every Debian arch.
COPY --from=mosquitto_builder /usr/local/lib/libmosquitto* /usr/lib/

COPY --from=mosquitto_builder /usr/local/bin/mosquitto_passwd /usr/bin/mosquitto_passwd
COPY --from=mosquitto_builder /usr/local/bin/mosquitto_sub /usr/bin/mosquitto_sub
COPY --from=mosquitto_builder /usr/local/bin/mosquitto_pub /usr/bin/mosquitto_pub
COPY --from=mosquitto_builder /usr/local/bin/mosquitto_rr /usr/bin/mosquitto_rr

# Config is rendered at runtime from a template so no secret is baked into the image.
# entrypoint.sh substitutes ${REDIS_PASSWORD} into mosquitto.conf.template before start.
COPY ./config/mosquitto.conf.template /etc/mosquitto/mosquitto.conf.template
COPY ./entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 1883 1884 8883

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]

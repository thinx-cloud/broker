
#Use debian:buster as a builder and then copy everything.
FROM debian:buster

#Set mosquitto and plugin versions.
#Change them for your needs.
# Latest is mosquitto-2.0.7 (04-Feb-2021) - build fails with missing cJSON dependency, originally 1.6.10
ENV MOSQUITTO_VERSION=2.0.14
ENV PLUGIN_VERSION=0.6.1
ENV GO_VERSION=1.16

WORKDIR /app

# Get mosquitto build dependencies.
RUN apt-get update -y && \
    apt-get install --no-install-recommends -y \
    libwebsockets8 \
    libwebsockets-dev \
    libc-ares2 \
    libc-ares-dev \
    openssl \
    uuid \
    uuid-dev \
    wget \
    build-essential \
    git \
    ca-certificates \
    && update-ca-certificates

RUN mkdir -p mosquitto/auth mosquitto/conf.d

RUN wget http://mosquitto.org/files/source/mosquitto-${MOSQUITTO_VERSION}.tar.gz
RUN tar xzvf mosquitto-${MOSQUITTO_VERSION}.tar.gz && rm mosquitto-${MOSQUITTO_VERSION}.tar.gz 

RUN wget https://github.com/DaveGamble/cJSON/archive/refs/tags/v1.7.15.tar.gz
RUN tar v1.7.15.tar.gz && rm v1.7.15.tar.gz

#Build cJSON
RUN cd v1.7.15 && mkdir build && cd build && cmake .. -DENABLE_CJSON_UTILS=On -DENABLE_CJSON_TEST=Off -DCMAKE_INSTALL_PREFIX=/usr && make install && cd ..

#Build mosquitto.
RUN cd mosquitto-${MOSQUITTO_VERSION} && make WITH_WEBSOCKETS=yes && make install && cd ..

#Get Go.
RUN export GO_ARCH=$(uname -m | sed -es/x86_64/amd64/ -es/armv7l/armv6l/ -es/aarch64/arm64/) && \
    wget --no-check-certificate https://dl.google.com/go/go${GO_VERSION}.linux-${GO_ARCH}.tar.gz && \
    tar -C /usr/local -xzf go${GO_VERSION}.linux-${GO_ARCH}.tar.gz && \
    export PATH=$PATH:/usr/local/go/bin && \
    go version && \
    rm go${GO_VERSION}.linux-${GO_ARCH}.tar.gz

# Build the plugin from local source
COPY ./goauth ./

# Build the plugin.
RUN export PATH=$PATH:/usr/local/go/bin && \
    export CGO_CFLAGS="-I/usr/local/include -fPIC" && \
    export CGO_LDFLAGS="-shared" && \
    make WITH_CJSON=no WITH_DOCS=no WITH_BUNDLED_DEPS=no

#Start from a new image.
FROM debian:buster

LABEL name="thinxcloud/mosquitto" version="2.0.14"

# Get mosquitto dependencies.
RUN apt-get update && apt-get install --no-install-recommends -y libwebsockets8 libc-ares2 openssl uuid redis

# Setup mosquitto env.
RUN mkdir -p /var/lib/mosquitto /var/log/mosquitto 
RUN groupadd mosquitto \
    && useradd -s /sbin/nologin mosquitto -g mosquitto -d /var/lib/mosquitto \
    && chown -R mosquitto:mosquitto /var/log/mosquitto/ \
    && chown -R mosquitto:mosquitto /var/lib/mosquitto/

# Copy confs, plugin so and mosquitto binary.
COPY --from=0 /app/mosquitto/ /mosquitto/
COPY --from=0 /app/pw /mosquitto/pw
COPY --from=0 /app/go-auth.so /mosquitto/go-auth.so
COPY --from=0 /usr/local/sbin/mosquitto /usr/sbin/mosquitto

# Expose tcp and websocket ports as defined at mosquitto.conf (change accordingly).
EXPOSE 1883 8883 1884

ENTRYPOINT ["sh", "-c", "/usr/sbin/mosquitto -c /etc/mosquitto/mosquitto.conf" ]
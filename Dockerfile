FROM golang:1.22-bullseye AS builder
LABEL maintainer="Joseph Lee <joseph@jc-lab.net>"

# Install deps
RUN apt-get update && apt-get install -y \
  libssl-dev \
  ca-certificates \
  fuse \
  git \
  gawk patch

ARG TARGETOS TARGETARCH

ENV SRC_DIR /kubo

# v0.30.0
ARG KUBO_COMMIT=846c5ccf679eeda58e626969bee8e80685be4812

RUN git clone https://github.com/ipfs/kubo.git $SRC_DIR \
    && cd $SRC_DIR \
    && git checkout -f ${KUBO_COMMIT}

COPY patches /tmp/patches
RUN cd $SRC_DIR && \
    LIBP2P_VERSION=$(cat go.mod | gawk 'match($0, /go-libp2p (.+)$/, out) { print out[1]}') && \
    mkdir -p replaced-pkg && \
    git clone -b ${LIBP2P_VERSION} https://github.com/libp2p/go-libp2p.git replaced-pkg/go-libp2p && \
    for name in $(find /tmp/patches -type f -name "*.patch" | sort); do patch -p1 < $name; done

RUN cd $SRC_DIR \
  && go mod download \
  && go get github.com/ipfs/go-ds-s3@7ef7ee4dd660697a5b0860cdccd97bcd64729b31 \
  && printf "\ns3ds github.com/ipfs/go-ds-s3/plugin 0\n" >> plugin/loader/preload_list

# Preload an in-tree but disabled-by-default plugin by adding it to the IPFS_PLUGINS variable
# e.g. docker build --build-arg IPFS_PLUGINS="foo bar baz"
ARG IPFS_PLUGINS

# Allow for other targets to be built, e.g.: docker build --build-arg MAKE_TARGET="nofuse"
ARG MAKE_TARGET=build

# Build the thing.
# Also: fix getting HEAD commit hash via git rev-parse.
RUN cd $SRC_DIR \
  && mkdir -p .git/objects \
  && GOOS=$TARGETOS GOARCH=$TARGETARCH GOFLAGS=-buildvcs=false make ${MAKE_TARGET} IPFS_PLUGINS=$IPFS_PLUGINS

# Using Debian Buster because the version of busybox we're using is based on it
# and we want to make sure the libraries we're using are compatible. That's also
# why we're running this for the target platform.
FROM debian:bullseye-slim AS utilities
RUN set -eux; \
	apt-get update; \
	apt-get install -y \
		tini \
    # Using gosu (~2MB) instead of su-exec (~20KB) because it's easier to
    # install on Debian. Useful links:
    # - https://github.com/ncopa/su-exec#why-reinvent-gosu
    # - https://github.com/tianon/gosu/issues/52#issuecomment-441946745
		gosu \
    # This installs fusermount which we later copy over to the target image.
    fuse \
    ca-certificates \
    jq \
	; \
	rm -rf /var/lib/apt/lists/*

# Now comes the actual target image, which aims to be as small as possible.
FROM busybox:stable-glibc

# Get the ipfs binary, entrypoint script, and TLS CAs from the build container.
ENV SRC_DIR /kubo
COPY --from=utilities /usr/sbin/gosu /sbin/gosu
COPY --from=utilities /usr/bin/tini /sbin/tini
COPY --from=utilities /bin/fusermount /usr/local/bin/fusermount
COPY --from=utilities /etc/ssl/certs /etc/ssl/certs
COPY --from=builder $SRC_DIR/cmd/ipfs/ipfs /usr/local/bin/ipfs
COPY --from=builder $SRC_DIR/bin/container_daemon /usr/local/bin/start_ipfs
COPY --from=builder $SRC_DIR/bin/container_init_run /usr/local/bin/container_init_run
COPY --from=builder /usr/bin/ldd /bin/bash /usr/bin/

# This shared lib (part of glibc) doesn't seem to be included with busybox.
COPY --from=builder /lib/*-linux-gnu*/libdl.so.2 /lib/

# Copy over SSL libraries.
COPY --from=builder /usr/lib/*-linux-gnu*/libssl.so* /usr/lib/
COPY --from=builder /usr/lib/*-linux-gnu*/libcrypto.so* /usr/lib/

# COPY jq
COPY --from=utilities /usr/bin/jq /usr/bin/
COPY --from=utilities /usr/lib/*-linux-gnu*/libjq.so* /usr/lib/
COPY --from=utilities /usr/lib/*-linux-gnu*/libonig.so* /usr/lib/

# Add suid bit on fusermount so it will run properly
RUN chmod 4755 /usr/local/bin/fusermount

# Fix permissions on start_ipfs (ignore the build machine's permissions)
RUN chmod 0755 /usr/local/bin/start_ipfs

# Swarm TCP; should be exposed to the public
EXPOSE 4001
# Swarm UDP; should be exposed to the public
EXPOSE 4001/udp
# Daemon API; must not be exposed publicly but to client services under you control
EXPOSE 5001
# Web Gateway; can be exposed publicly with a proxy, e.g. as https://ipfs.example.org
EXPOSE 8080
# Swarm Websockets; must be exposed publicly when the node is listening using the websocket transport (/ipX/.../tcp/8081/ws).
EXPOSE 8081

# Create the fs-repo directory and switch to a non-privileged user.
ENV IPFS_PATH /data/ipfs
RUN mkdir -p $IPFS_PATH \
  && adduser -D -h $IPFS_PATH -u 1000 -G users ipfs \
  && chown ipfs:users $IPFS_PATH

# Create mount points for `ipfs mount` command
RUN mkdir /ipfs /ipns \
  && chown ipfs:users /ipfs /ipns

# Create the init scripts directory
RUN mkdir /container-init.d \
  && chown ipfs:users /container-init.d

# Expose the fs-repo as a volume.
# start_ipfs initializes an fs-repo if none is mounted.
# Important this happens after the USER directive so permissions are correct.
VOLUME $IPFS_PATH

# The default logging level
ENV IPFS_LOGGING ""

# This just makes sure that:
# 1. There's an fs-repo, and initializes one if there isn't.
# 2. The API and Gateway are accessible from outside the container.
ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/start_ipfs"]

# Healthcheck for the container
# QmUNLLsPACCz1vLxQVkXqqLX5R1X345qqfHbsf67hvA3Nn is the CID of empty folder
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD ipfs --api=/ip4/127.0.0.1/tcp/5001 dag stat /ipfs/QmUNLLsPACCz1vLxQVkXqqLX5R1X345qqfHbsf67hvA3Nn || exit 1

# Execute the daemon subcommand by default
CMD ["daemon", "--migrate=true", "--agent-version-suffix=docker"]

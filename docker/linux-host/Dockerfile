FROM elixir:1.20.4-otp-28

ARG DEBIAN_FRONTEND=noninteractive
ARG TARGETARCH
ARG GO_VERSION=1.26.4
ARG GO_AMD64_SHA256=1153d3d50e0ac764b447adfe05c2bcf08e889d42a02e0fe0259bd47f6733ad7f
ARG GO_ARM64_SHA256=ef758ae7c6cf9267c9c0ef080b8965f453d89ab2d25d9eb22de4405925238768

RUN apt-get update \
    && apt-get install --no-install-recommends --yes ca-certificates curl fuse-overlayfs git nftables podman slirp4netns uidmap xz-utils \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --create-home --shell /bin/bash biot \
    && usermod --add-subuids 100000-165535 --add-subgids 100000-165535 biot \
    && mkdir --mode=0755 /nix \
    && chown biot:biot /nix

RUN case "$TARGETARCH" in \
      amd64) checksum="$GO_AMD64_SHA256" ;; \
      arm64) checksum="$GO_ARM64_SHA256" ;; \
      *) echo "unsupported Go architecture: $TARGETARCH" >&2; exit 1 ;; \
    esac \
    && curl --proto '=https' --tlsv1.2 --location \
      "https://go.dev/dl/go${GO_VERSION}.linux-${TARGETARCH}.tar.gz" \
      --output /tmp/go.tar.gz \
    && echo "$checksum  /tmp/go.tar.gz" | sha256sum --check --strict \
    && tar --directory /usr/local --extract --gzip --file /tmp/go.tar.gz \
    && rm /tmp/go.tar.gz

USER biot
WORKDIR /workspace
ENV PATH="/usr/local/go/bin:/home/biot/.nix-profile/bin:${PATH}"

RUN curl --proto '=https' --tlsv1.2 --location https://nixos.org/nix/install \
    | sh -s -- --no-daemon

ENTRYPOINT ["/bin/bash"]

FROM elixir:1.20.4-otp-28

ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install --no-install-recommends --yes ca-certificates curl fuse-overlayfs git podman slirp4netns uidmap xz-utils \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --create-home --shell /bin/bash biot \
    && printf 'biot:100000:65536\n' >> /etc/subuid \
    && printf 'biot:100000:65536\n' >> /etc/subgid \
    && mkdir --mode=0755 /nix \
    && chown biot:biot /nix

USER biot
WORKDIR /workspace
ENV PATH="/home/biot/.nix-profile/bin:${PATH}"

RUN curl --proto '=https' --tlsv1.2 --location https://nixos.org/nix/install \
    | sh -s -- --no-daemon

ENTRYPOINT ["/bin/bash"]

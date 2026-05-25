# syntax=docker/dockerfile:1.6
#
# Atlas builder container image.
#
# This image bakes everything a deploy job needs into a single layer:
# Erlang + Elixir (via the hexpm base image), Node.js, Terraform, the
# AWS CLI, the AWS SSM session-manager-plugin, Ansible plus its Galaxy
# collections and pip dependencies, jq / sudo / unzip / curl, and a
# non-root `builder` user (uid 1001, gid 1001) with passwordless sudo
# at `/etc/sudoers.d/builder`. The default workdir `/workspace` is owned
# by `builder`.
#
# Versions are pinned at build time via --build-arg. Override any of
# them to track different upstream releases:
#
#   docker build \
#     -f apps/atlas/priv/docker/builder/Dockerfile \
#     --build-arg ELIXIR_VERSION=1.18.0 \
#     --build-arg ERLANG_VERSION=27.1 \
#     --build-arg DEBIAN_RELEASE=bookworm \
#     --build-arg DEBIAN_SNAPSHOT=20240701-slim \
#     --build-arg TERRAFORM_VERSION=1.9.5 \
#     --build-arg NODE_MAJOR=20 \
#     -t atlas-builder:latest \
#     apps/atlas/priv
#
# The build context MUST be `apps/atlas/priv` (or `priv/` when this
# Dockerfile is consumed via Application.app_dir/2 from a dependency
# project) because the `COPY` statements below read
# `ansible/requirements.txt` and `ansible/requirements.yml` from that
# subtree.

ARG ELIXIR_VERSION=1.18.0
ARG ERLANG_VERSION=27.1
ARG DEBIAN_RELEASE=bookworm
ARG DEBIAN_SNAPSHOT=20240701-slim

FROM hexpm/elixir:${ELIXIR_VERSION}-erlang-${ERLANG_VERSION}-debian-${DEBIAN_RELEASE}-${DEBIAN_SNAPSHOT}

# ARGs declared before the first FROM do not propagate into stages
# automatically. Re-declare anything we need below.
ARG TERRAFORM_VERSION=1.9.5
ARG NODE_MAJOR=20
ARG TARGETARCH=amd64
ARG BUILDER_UID=1001
ARG BUILDER_GID=1001

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

# ---- Base OS packages --------------------------------------------------
# jq, sudo, unzip, curl, ca-certificates are PLAN.md A1 requirements.
# build-essential / libffi-dev / libssl-dev are pip-build prerequisites
# for the cryptography wheel that boto3 transitively requires.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
         build-essential \
         ca-certificates \
         curl \
         git \
         gnupg \
         jq \
         libffi-dev \
         libssl-dev \
         python3 \
         python3-pip \
         python3-venv \
         sudo \
         unzip \
    && rm -rf /var/lib/apt/lists/*

# ---- Node.js (NodeSource) ---------------------------------------------
RUN curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

# ---- Terraform --------------------------------------------------------
RUN curl -fsSL -o /tmp/terraform.zip \
      "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_${TARGETARCH}.zip" \
    && unzip -d /usr/local/bin /tmp/terraform.zip \
    && rm /tmp/terraform.zip \
    && chmod +x /usr/local/bin/terraform \
    && terraform version

# ---- AWS CLI v2 -------------------------------------------------------
RUN ARCH="$(uname -m)" \
    && curl -fsSL -o /tmp/awscliv2.zip "https://awscli.amazonaws.com/awscli-exe-linux-${ARCH}.zip" \
    && unzip -q /tmp/awscliv2.zip -d /tmp \
    && /tmp/aws/install \
    && rm -rf /tmp/aws /tmp/awscliv2.zip \
    && aws --version

# ---- AWS SSM session-manager-plugin (.deb) ----------------------------
# Pulled from the canonical S3 location named in PLAN.md A1.
RUN curl -fsSL -o /tmp/session-manager-plugin.deb \
      "https://s3.amazonaws.com/session-manager-downloads/plugin/latest/ubuntu_64bit/session-manager-plugin.deb" \
    && dpkg -i /tmp/session-manager-plugin.deb \
    && rm /tmp/session-manager-plugin.deb \
    && session-manager-plugin --version

# ---- Ansible + Galaxy collections + pip extras ------------------------
# requirements.txt and requirements.yml live next to this Dockerfile in
# the build context (apps/atlas/priv/ansible/). Consumers that need
# additional collections or pip packages add their own overlay or
# extend the image.
COPY ansible/requirements.txt /tmp/ansible-requirements.txt
COPY ansible/requirements.yml /tmp/ansible-requirements.yml

RUN pip3 install --break-system-packages --no-cache-dir \
      -r /tmp/ansible-requirements.txt \
    && ansible-galaxy collection install \
       -r /tmp/ansible-requirements.yml \
       -p /usr/share/ansible/collections \
    && rm /tmp/ansible-requirements.txt /tmp/ansible-requirements.yml \
    && ansible --version

# ---- Hex / rebar (Mix prerequisites) ----------------------------------
RUN mix local.hex --force \
    && mix local.rebar --force

# ---- Non-root builder user with passwordless sudo ---------------------
RUN groupadd --gid ${BUILDER_GID} builder \
    && useradd --uid ${BUILDER_UID} --gid ${BUILDER_GID} \
         --create-home --shell /bin/bash builder \
    && printf 'builder ALL=(ALL) NOPASSWD: ALL\n' > /etc/sudoers.d/builder \
    && chmod 0440 /etc/sudoers.d/builder \
    && visudo -c -f /etc/sudoers.d/builder

# ---- Workspace --------------------------------------------------------
WORKDIR /workspace
RUN chown -R builder:builder /workspace

# Also let `builder` write Hex/Rebar caches in its home; mix local.* above
# wrote to /root, so re-run as builder so the cache exists in $HOME too.
USER builder
RUN mix local.hex --force \
    && mix local.rebar --force

CMD ["bash"]

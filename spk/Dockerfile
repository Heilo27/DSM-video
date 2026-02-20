# Dockerfile for building Synology SPK packages
# Uses Synology's official toolkit for DSM 7.2

FROM ubuntu:20.04

# Avoid interactive prompts
ENV DEBIAN_FRONTEND=noninteractive

# Install dependencies
RUN apt-get update && apt-get install -y \
    wget \
    tar \
    xz-utils \
    python3 \
    python3-pip \
    build-essential \
    git \
    && rm -rf /var/lib/apt/lists/*

# Set working directory
WORKDIR /toolkit

# Download and extract Synology base_env (DSM 7.2)
# This provides the pkgscripts-ng toolchain
RUN wget -q https://global.synologydownload.com/download/ToolChain/toolkit/7.2/base/base_env-7.2.txz -O base_env-7.2.txz && \
    tar -xf base_env-7.2.txz && \
    rm base_env-7.2.txz

# Set up environment
ENV PATH="/toolkit/pkgscripts-ng:${PATH}"

# Create source directory structure
RUN mkdir -p /source

WORKDIR /source

# Default command
CMD ["/bin/bash"]

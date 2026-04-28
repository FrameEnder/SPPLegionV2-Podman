# ============================================================
# SPP Server Base Image
# Ubuntu 24.04 LTS + Wine 11 (WineHQ stable)
# ============================================================
FROM ubuntu:24.04

# Avoid interactive prompts during package install
ENV DEBIAN_FRONTEND=noninteractive
ENV WINEDEBUG=-all
ENV WINEPREFIX=/root/.wine

# Enable 32-bit architecture (required by Wine)
RUN dpkg --add-architecture i386

# Install base dependencies + WineHQ repo
RUN apt-get update && apt-get install -y \
    wget \
    gnupg2 \
    software-properties-common \
    ca-certificates \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Add WineHQ official repository (Wine 11 stable)
RUN mkdir -pm755 /etc/apt/keyrings && \
    wget -O /etc/apt/keyrings/winehq-archive.key \
        https://dl.winehq.org/wine-builds/winehq.key && \
    wget -NP /etc/apt/sources.list.d/ \
        https://dl.winehq.org/wine-builds/ubuntu/dists/noble/winehq-noble.sources

# Install Wine 11 stable
RUN apt-get update && apt-get install -y --install-recommends \
    winehq-stable \
    && rm -rf /var/lib/apt/lists/*

# Install winetricks for runtime dependencies
RUN wget -q https://raw.githubusercontent.com/Winetricks/winetricks/master/src/winetricks \
    -O /usr/local/bin/winetricks && \
    chmod +x /usr/local/bin/winetricks

# Create the SPP server directory
RUN mkdir -p /opt/spp

# Initialize Wine prefix silently
RUN wineboot --init 2>/dev/null || true

WORKDIR /opt/spp

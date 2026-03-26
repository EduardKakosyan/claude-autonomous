FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y \
    git curl sudo ca-certificates \
    ripgrep fd-find jq tree htop unzip \
    nodejs npm make bc \
    iptables ipset socat \
    && rm -rf /var/lib/apt/lists/*

# Install Go 1.23
ARG GO_VERSION=1.23.8
RUN curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-arm64.tar.gz" \
    | tar -C /usr/local -xz
ENV PATH="/usr/local/go/bin:${PATH}"

# Install Go dev tools (as root, then move to /usr/local/bin)
RUN GOBIN=/usr/local/bin go install golang.org/x/tools/cmd/goimports@latest \
    && GOBIN=/usr/local/bin go install github.com/golangci/golangci-lint/v2/cmd/golangci-lint@latest \
    && GOBIN=/usr/local/bin go install golang.org/x/vuln/cmd/govulncheck@latest \
    && rm -rf /root/go

# Non-root user with sudo (contained by Docker boundaries)
ARG USERNAME=claude
RUN groupadd --gid 1001 $USERNAME \
    && useradd --uid 1001 --gid 1001 -m $USERNAME \
    && echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

# Install Claude Code via native installer (as claude user)
USER $USERNAME
RUN curl -fsSL https://claude.ai/install.sh | bash
ENV PATH="/home/claude/.local/bin:${PATH}"

# Disable auto-updater for container stability
ENV DISABLE_AUTOUPDATER=1

# Set up Go paths for claude user
RUN mkdir -p /home/claude/go/bin
ENV GOPATH="/home/claude/go"

# Firewall script (needs root to copy, then switch back)
USER root
COPY init-firewall.sh /usr/local/bin/init-firewall.sh
RUN chmod +x /usr/local/bin/init-firewall.sh

RUN mkdir -p /workspace && chown $USERNAME:$USERNAME /workspace
WORKDIR /workspace
USER $USERNAME

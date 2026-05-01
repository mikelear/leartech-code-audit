# Code standards audit — runs leartech convention rules against repo main branches.
# Uses semgrep for scanning + leartech-specific rules.
# Builds on top of security-tools for semgrep, jq, git.

FROM ghcr.io/mikelear/security-tools:latest

# Copy audit script and leartech rules (rules already in base image,
# but we copy our own to ensure they're up to date with this repo)
COPY app/ /app/
RUN chmod +x /app/*.sh

WORKDIR /workspace

CMD ["/app/cron-audit.sh"]

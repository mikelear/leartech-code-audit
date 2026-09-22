# Code standards audit — runs leartech convention rules against repo main branches.
# Uses semgrep for scanning + leartech-specific rules.
# Builds on top of security-tools for semgrep, jq, git.

FROM ghcr.io/mikelear/security-tools:0.51.11@sha256:2e17c3dde389b2ea984562f2e5f7c616f6b26f6539cd4b4ab0ca38c537bda0ee

# The semgrep rules come from the base image at /app/rules/leartech; this repo
# holds no rules/ directory of its own. So a rule change in
# leartech-dockerfiles/security-tools only reaches the running audit when this
# pin moves and this image is rebuilt.
COPY app/ /app/
RUN chmod +x /app/*.sh

WORKDIR /workspace

CMD ["/app/cron-audit.sh"]

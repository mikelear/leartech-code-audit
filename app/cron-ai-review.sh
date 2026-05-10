#!/bin/bash
# Full AI review audit: run the complete AI review pipeline against main branches.
# Uses 3 LLMs (Ollama + Claude + DeepSeek) + classifier advisory.
# Posts GitHub Issues for repos that score below threshold.
#
# Usage: /app/cron-ai-review.sh --repos "repo1,repo2" --org mikelear \
#          --cluster-id gcp --token ghp_xxx --threshold 70
set -euo pipefail

# Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repos) REPOS="$2"; shift 2 ;;
    --org) ORG="$2"; shift 2 ;;
    --cluster-id) CLUSTER_ID="$2"; shift 2 ;;
    --token) GIT_TOKEN="$2"; shift 2 ;;
    --threshold) THRESHOLD="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

ORG="${ORG:-mikelear}"
CLUSTER_ID="${CLUSTER_ID:-unknown}"
DRY_RUN="${DRY_RUN:-false}"
THRESHOLD="${THRESHOLD:-70}"
WORK_DIR="/tmp/ai-review-audit"
AUDIT_LABEL="audit-ai-review"
TOTAL_ISSUES=0

# Endpoints
OLLAMA_ENDPOINT="${OLLAMA_ENDPOINT:-http://ollama.ai-inference.svc.cluster.local:11434}"
CHROMADB_ENDPOINT="${CHROMADB_ENDPOINT:-http://ai-inference-resources-chromadb.ai-inference.svc.cluster.local:8000}"
CLASSIFIER_ENDPOINT="${CLASSIFIER_ENDPOINT:-http://leartech-ai-classifier.jx-staging.svc.cluster.local:8080}"
OLLAMA_MODEL="${OLLAMA_MODEL:-qwen2.5-coder:14b}"

echo "=== AI Review Audit [${CLUSTER_ID}] ==="
echo "Repos: $(echo "$REPOS" | tr ',' '\n' | wc -l | tr -d ' ')"
echo "Threshold: ${THRESHOLD}/100"
echo "Dry run: $DRY_RUN"
echo ""

mkdir -p "$WORK_DIR"

# Clone standards repo once
STANDARDS_DIR="$WORK_DIR/standards"
git clone --depth 1 "https://x-access-token:${GIT_TOKEN}@github.com/${ORG}/leartech-llm-training-data.git" "$STANDARDS_DIR" 2>/dev/null || {
  echo "WARNING: Failed to clone standards repo"
  STANDARDS_DIR=""
}

IFS=',' read -ra REPO_LIST <<< "$REPOS"

for REPO in "${REPO_LIST[@]}"; do
  REPO=$(echo "$REPO" | xargs)
  REPO_DIR="$WORK_DIR/$REPO"
  echo "============================================================"
  echo "Reviewing: $ORG/$REPO (main)"
  echo "============================================================"

  # Clone
  git clone --depth 1 "https://x-access-token:${GIT_TOKEN}@github.com/${ORG}/${REPO}.git" "$REPO_DIR" 2>/dev/null || {
    echo "  SKIP: failed to clone $ORG/$REPO"
    continue
  }

  # Generate a diff of the full repo (all files as "added")
  # This gives the LLMs the full codebase to review
  cd "$REPO_DIR"
  DIFF_FILE="$WORK_DIR/${REPO}-diff.txt"

  # Use git diff against empty tree to get all files as additions
  git diff --no-index /dev/null . 2>/dev/null | head -50000 > "$DIFF_FILE" || true

  # If diff is empty or too small, generate from file listing
  if [ ! -s "$DIFF_FILE" ] || [ "$(wc -c < "$DIFF_FILE")" -lt 100 ]; then
    find . -type f \( -name "*.go" -o -name "*.ts" -o -name "*.py" -o -name "*.yaml" -o -name "*.yml" \) \
      -not -path "./.git/*" -not -path "*/node_modules/*" -not -path "*/vendor/*" \
      -exec sh -c 'echo "diff --git a/{} b/{}"; echo "+++ b/{}"; cat "{}" | head -200 | sed "s/^/+/"' \; \
      > "$DIFF_FILE" 2>/dev/null || true
  fi

  DIFF_SIZE=$(wc -c < "$DIFF_FILE" | tr -d ' ')
  echo "  Diff size: $DIFF_SIZE chars"

  # Truncate if too large (keep under 30K for LLM context)
  if [ "$DIFF_SIZE" -gt 30000 ]; then
    head -c 30000 "$DIFF_FILE" > "${DIFF_FILE}.tmp" && mv "${DIFF_FILE}.tmp" "$DIFF_FILE"
    echo "  Truncated to 30K chars"
  fi

  cd "$WORK_DIR"

  # Filter diff
  if [ -n "$STANDARDS_DIR" ] && [ -f "$STANDARDS_DIR/.reviewignore" ]; then
    python3 /app/filter_diff.py "$DIFF_FILE" "${DIFF_FILE}.filtered" "$REPO_DIR/.reviewignore" "$STANDARDS_DIR/.reviewignore" 2>/dev/null && mv "${DIFF_FILE}.filtered" "$DIFF_FILE" || true
  fi

  # RAG query (non-blocking)
  RAG_CONTEXT=""
  RAG_FILE="$WORK_DIR/${REPO}-rag.txt"
  python3 /app/rag_query.py \
    --chromadb-url "$CHROMADB_ENDPOINT" \
    --collection code-reviews \
    --diff "$DIFF_FILE" \
    --output "$RAG_FILE" 2>/dev/null || true
  [ -s "$RAG_FILE" ] && RAG_CONTEXT="$RAG_FILE"

  # Run reviews (each tolerant of failures)
  REVIEWS=""

  # Ollama
  if python3 -c "import httpx; httpx.get('$OLLAMA_ENDPOINT/api/tags', timeout=5)" 2>/dev/null; then
    python3 /app/review.py \
      --provider ollama \
      --endpoint "$OLLAMA_ENDPOINT" \
      --model "$OLLAMA_MODEL" \
      --diff "$DIFF_FILE" \
      --rag-context "$RAG_CONTEXT" \
      --standards-dir "$STANDARDS_DIR" \
      --output "$WORK_DIR/${REPO}-review-ollama.json" || echo "  Ollama review failed"
  fi

  # Claude
  if [ -n "${CLAUDE_API_KEY:-}" ]; then
    python3 /app/review.py \
      --provider claude \
      --endpoint "https://api.anthropic.com/v1/messages" \
      --model "claude-sonnet-4-20250514" \
      --diff "$DIFF_FILE" \
      --rag-context "$RAG_CONTEXT" \
      --standards-dir "$STANDARDS_DIR" \
      --output "$WORK_DIR/${REPO}-review-claude.json" || echo "  Claude review failed"
  fi

  # DeepSeek
  if [ -n "${DEEPSEEK_API_KEY:-}" ]; then
    python3 /app/review.py \
      --provider deepseek \
      --endpoint "https://api.deepseek.com/v1/chat/completions" \
      --model "deepseek-chat" \
      --diff "$DIFF_FILE" \
      --rag-context "$RAG_CONTEXT" \
      --standards-dir "$STANDARDS_DIR" \
      --output "$WORK_DIR/${REPO}-review-deepseek.json" || echo "  DeepSeek review failed"
  fi

  # Collect reviews
  for f in "$WORK_DIR/${REPO}-review-ollama.json" "$WORK_DIR/${REPO}-review-claude.json" "$WORK_DIR/${REPO}-review-deepseek.json"; do
    [ -f "$f" ] && REVIEWS="$REVIEWS $f"
  done
  REVIEWS=$(echo $REVIEWS | xargs)
  REVIEW_COUNT=$(echo $REVIEWS | wc -w | tr -d ' ')

  if [ "$REVIEW_COUNT" -eq 0 ]; then
    echo "  No reviews available, skipping"
    rm -rf "$REPO_DIR"
    continue
  fi

  # Aggregate
  REVIEW_LIST=$(echo $REVIEWS | tr ' ' ',')
  python3 /app/aggregate.py \
    --reviews "$REVIEW_LIST" \
    --threshold "$REVIEW_COUNT" \
    --output "$WORK_DIR/${REPO}-aggregate.json" || {
    echo "  Aggregate failed"
    rm -rf "$REPO_DIR"
    continue
  }

  # Classifier advisory
  CLASSIFIER_VERDICT="N/A"
  CLASSIFIER_CONF="0"
  if python3 -c "import urllib.request; urllib.request.urlopen('$CLASSIFIER_ENDPOINT/health', timeout=3)" 2>/dev/null; then
    DIFF_CONTENT=$(cat "$DIFF_FILE" | head -c 50000)
    CLASSIFIER_RESULT=$(python3 -c "
import urllib.request, json, sys
diff = open('$DIFF_FILE').read()[:50000]
req = urllib.request.Request(
    '$CLASSIFIER_ENDPOINT/predict',
    data=json.dumps({'diff': diff}).encode(),
    headers={'Content-Type': 'application/json'},
    method='POST',
)
try:
    r = json.loads(urllib.request.urlopen(req, timeout=10).read())
    print(json.dumps(r))
except: print('{}')
" 2>/dev/null) || true
    if [ -n "$CLASSIFIER_RESULT" ] && [ "$CLASSIFIER_RESULT" != "{}" ]; then
      CLASSIFIER_VERDICT=$(echo "$CLASSIFIER_RESULT" | python3 -c "import json,sys; print(json.load(sys.stdin).get('verdict','?'))" 2>/dev/null || echo "?")
      CLASSIFIER_CONF=$(echo "$CLASSIFIER_RESULT" | python3 -c "import json,sys; print(f'{json.load(sys.stdin).get(\"confidence\",0):.0%}')" 2>/dev/null || echo "?")
    fi
  fi

  # Read aggregate result
  SCORE=$(python3 -c "import json; print(json.load(open('$WORK_DIR/${REPO}-aggregate.json')).get('overall_score', 0))" 2>/dev/null || echo "0")
  VERDICT=$(python3 -c "import json; print(json.load(open('$WORK_DIR/${REPO}-aggregate.json')).get('overall_verdict', 'ERROR'))" 2>/dev/null || echo "ERROR")
  ISSUES_COUNT=$(python3 -c "import json; print(len(json.load(open('$WORK_DIR/${REPO}-aggregate.json')).get('all_issues', [])))" 2>/dev/null || echo "0")
  SUGGESTIONS_COUNT=$(python3 -c "import json; print(len(json.load(open('$WORK_DIR/${REPO}-aggregate.json')).get('all_suggestions', [])))" 2>/dev/null || echo "0")

  echo "  Score: $SCORE/100 ($VERDICT) | Issues: $ISSUES_COUNT | Suggestions: $SUGGESTIONS_COUNT | Classifier: $CLASSIFIER_VERDICT ($CLASSIFIER_CONF)"

  # Only create issue if below threshold
  if [ "$SCORE" -lt "$THRESHOLD" ]; then
    echo "  Below threshold ($THRESHOLD) — creating issue"

    # Build individual reviewer scores table
    REVIEWER_TABLE=$(python3 -c "
import json
agg = json.load(open('$WORK_DIR/${REPO}-aggregate.json'))
for r in agg.get('individual_reviews', []):
    score = r.get('score', 0)
    verdict = r.get('verdict', '?')
    provider = r.get('provider', '?')
    model = r.get('model', '?')
    skipped = '⚠ SKIPPED' if r.get('skipped') else ''
    outlier = '~~OUTLIER~~' if r.get('outlier') else ''
    display = skipped or outlier or f'**{score}/100**'
    print(f'| {provider} | \`{model}\` | {display} | {verdict} |')
" 2>/dev/null || echo "| ? | ? | ? | ? |")

    # Build issues table (top 10)
    ISSUES_TABLE=$(python3 -c "
import json
agg = json.load(open('$WORK_DIR/${REPO}-aggregate.json'))
for issue in agg.get('all_issues', [])[:10]:
    sev = issue.get('severity', 'info')
    msg = issue.get('message', issue.get('description', '?'))[:80]
    loc = issue.get('file', '')
    line = issue.get('line', '')
    by = issue.get('reported_by', '?')
    loc_str = f'\`{loc}:{line}\`' if loc else ''
    print(f'| {sev} | [{by}] {loc_str} | {msg} |')
" 2>/dev/null || echo "")

    ISSUE_TITLE="[ai-review-audit] ${REPO}: ${SCORE}/100 ${VERDICT}"
    ISSUE_BODY="## AI Review Audit — ${REPO}

Full AI review of \`main\` branch scored **${SCORE}/100** (**${VERDICT}**).

### Reviewer Scores

| Reviewer | Model | Score | Verdict |
|---|---|---|---|
${REVIEWER_TABLE}

### Classifier Advisory

**${CLASSIFIER_VERDICT}** (confidence: ${CLASSIFIER_CONF})

### Issues Found (${ISSUES_COUNT})

| Severity | Location | Message |
|---|---|---|
${ISSUES_TABLE}

### Suggestions (${SUGGESTIONS_COUNT})

See full aggregate result for details.

---

**Threshold:** ${THRESHOLD}/100. Repos scoring above this are not flagged.

*Generated by AI Review Audit CronJob [\`${CLUSTER_ID}\`]*"

    # Check for existing open issue
    EXISTING=$(curl -s -H "Authorization: token $GIT_TOKEN" \
      "https://api.github.com/repos/${ORG}/${REPO}/issues?labels=${AUDIT_LABEL}&state=open&per_page=1" \
      | jq 'length' 2>/dev/null || echo "0")

    if [ "$DRY_RUN" = "false" ]; then
      if [ "$EXISTING" -gt 0 ]; then
        ISSUE_NUMBER=$(curl -s -H "Authorization: token $GIT_TOKEN" \
          "https://api.github.com/repos/${ORG}/${REPO}/issues?labels=${AUDIT_LABEL}&state=open&per_page=1" \
          | jq '.[0].number')
        curl -s -o /dev/null -X PATCH \
          -H "Authorization: token $GIT_TOKEN" \
          -H "Accept: application/vnd.github.v3+json" \
          "https://api.github.com/repos/${ORG}/${REPO}/issues/${ISSUE_NUMBER}" \
          -d "$(jq -n --arg title "$ISSUE_TITLE" --arg body "$ISSUE_BODY" '{title: $title, body: $body}')"
        echo "  Updated issue #${ISSUE_NUMBER}"
      else
        RESPONSE=$(curl -s -X POST \
          -H "Authorization: token $GIT_TOKEN" \
          -H "Accept: application/vnd.github.v3+json" \
          "https://api.github.com/repos/${ORG}/${REPO}/issues" \
          -d "$(jq -n --arg title "$ISSUE_TITLE" --arg body "$ISSUE_BODY" --arg label "$AUDIT_LABEL" \
            '{title: $title, body: $body, labels: [$label]}')")
        NEW_NUMBER=$(echo "$RESPONSE" | jq '.number')
        echo "  Created issue #${NEW_NUMBER}"
      fi
      TOTAL_ISSUES=$((TOTAL_ISSUES + 1))
    else
      echo "  DRY RUN: would create/update issue"
    fi
  else
    echo "  Above threshold — CLEAN"
  fi

  rm -rf "$REPO_DIR" "$WORK_DIR/${REPO}-"*
done

echo ""
echo "============================================================"
echo "AI Review Audit complete"
echo "  Repos reviewed: ${#REPO_LIST[@]}"
echo "  Issues created/updated: $TOTAL_ISSUES"
echo "============================================================"

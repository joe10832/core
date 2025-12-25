#!/usr/bin/env bash

set -euo pipefail

log() {
  local timestamp
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  echo "[$timestamp] $*"
}

log_error() {
  local timestamp
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  echo "[$timestamp] ERROR: $*" >&2
}

should_retry() {
  local status=${1:-0}
  if [ "$status" -ge 500 ] || [ "$status" -eq 429 ] || [ "$status" -eq 0 ]; then
    return 0
  fi
  return 1
}

api_request() {
  local method=$1
  local url=$2
  local data=${3-}
  local timeout=${API_TIMEOUT:-30}
  local tmp
  tmp=$(mktemp)

  local -a args=(
    --silent
    --show-error
    --max-time "$timeout"
    -X "$method"
    -H "Authorization: Bearer $GITHUB_TOKEN"
    -H "Accept: application/vnd.github+json"
    --output "$tmp"
    --write-out "%{http_code}"
  )

  if [ $# -ge 3 ]; then
    args+=(-H "Content-Type: application/json" --data "$data")
  fi

  local status
  status=$(curl "${args[@]}" "$url" || true)

  if ! [[ "$status" =~ ^[0-9]+$ ]]; then
    status=0
  fi

  API_STATUS=$status
  API_RESPONSE=$(cat "$tmp")
  rm -f "$tmp"
}

with_retry() {
  local method=$1
  local url=$2
  local data=${3-}
  local attempts=${MAX_RETRIES:-3}
  local delay=${RETRY_DELAY:-5}
  local attempt=1

  while [ $attempt -le $attempts ]; do
    if [ $# -ge 3 ]; then
      api_request "$method" "$url" "$data"
    else
      api_request "$method" "$url"
    fi

    if [ "$API_STATUS" -ge 200 ] && [ "$API_STATUS" -lt 300 ]; then
      return 0
    fi

    if ! should_retry "$API_STATUS" || [ $attempt -eq $attempts ]; then
      return 1
    fi

    log "Retrying $method $url in $delay seconds (status $API_STATUS)"
    sleep "$delay"
    attempt=$((attempt + 1))
  done
}

process_issues_in_batches() {
  local label=$1
  local per_page=$2
  local dry_run_raw=${3:-false}
  local dry_run=$(echo "$dry_run_raw" | tr '[:upper:]' '[:lower:]')
  local page=1
  local max_pages=${MAX_PAGES:-0}
  local processed=0
  local commented=0
  local closed=0
  local locked=0
  local skipped=0

  if ! [[ "$per_page" =~ ^[0-9]+$ ]] || [ "$per_page" -lt 1 ]; then
    log_error "Invalid batch size: $per_page"
    exit 1
  fi

  rm -f processing-stats.json

  while :; do
    if [ "$max_pages" -ne 0 ] && [ "$page" -gt "$max_pages" ]; then
      log "Reached max pages limit ($max_pages)."
      break
    fi

    local fetch_url
    fetch_url="https://api.github.com/repos/${GITHUB_REPOSITORY}/issues?state=open&labels=${label}&per_page=${per_page}&page=${page}"

    if ! with_retry "GET" "$fetch_url"; then
      log_error "Failed to fetch issues for page $page (status $API_STATUS)"
      log_error "$API_RESPONSE"
      exit 1
    fi

    local issue_count
    issue_count=$(echo "$API_RESPONSE" | jq length)

    if [ "$issue_count" -eq 0 ]; then
      log "No more issues found."
      break
    fi

    while IFS= read -r row; do
      local issue_number
      issue_number=$(echo "$row" | jq -r '.number')
      local issue_title
      issue_title=$(echo "$row" | jq -r '.title')
      local is_pull_request
      is_pull_request=$(echo "$row" | jq 'has("pull_request")')
      processed=$((processed + 1))

      if [ "$is_pull_request" = "true" ]; then
        log "Skipping pull request #$issue_number - $issue_title"
        skipped=$((skipped + 1))
        continue
      fi

      if [ "$dry_run" = "true" ]; then
        log "Dry run: would process issue #$issue_number - $issue_title"
        skipped=$((skipped + 1))
        continue
      fi

      local comment_payload
      comment_payload=$(jq -n --arg body "$CUSTOM_MESSAGE" '{body: $body}')

      if ! with_retry "POST" "https://api.github.com/repos/${GITHUB_REPOSITORY}/issues/${issue_number}/comments" "$comment_payload"; then
        log_error "Failed to comment on issue #$issue_number (status $API_STATUS)"
        log_error "$API_RESPONSE"
        exit 1
      fi
      commented=$((commented + 1))
      log "Commented on issue #$issue_number"

      local close_payload='{"state":"closed"}'
      if ! with_retry "PATCH" "https://api.github.com/repos/${GITHUB_REPOSITORY}/issues/${issue_number}" "$close_payload"; then
        log_error "Failed to close issue #$issue_number (status $API_STATUS)"
        log_error "$API_RESPONSE"
        exit 1
      fi
      closed=$((closed + 1))
      log "Closed issue #$issue_number"

      local lock_payload
      lock_payload=$(jq -n --arg reason "$LOCK_REASON" '{lock_reason: $reason}')
      if ! with_retry "PUT" "https://api.github.com/repos/${GITHUB_REPOSITORY}/issues/${issue_number}/lock" "$lock_payload"; then
        if [ "$API_STATUS" -eq 423 ]; then
          log "Issue #$issue_number already locked"
        else
          log_error "Failed to lock issue #$issue_number (status $API_STATUS)"
          log_error "$API_RESPONSE"
          exit 1
        fi
      else
        locked=$((locked + 1))
        log "Locked issue #$issue_number"
      fi
    done < <(echo "$API_RESPONSE" | jq -c '.[]')

    if [ "$issue_count" -lt "$per_page" ]; then
      break
    fi

    page=$((page + 1))
  done

  jq -n \
    --argjson processed "$processed" \
    --argjson commented "$commented" \
    --argjson closed "$closed" \
    --argjson locked "$locked" \
    --argjson skipped "$skipped" \
    '{processed: $processed, commented: $commented, closed: $closed, locked: $locked, skipped: $skipped}' > processing-stats.json

  log "Processing complete: processed=$processed commented=$commented closed=$closed locked=$locked skipped=$skipped"
}

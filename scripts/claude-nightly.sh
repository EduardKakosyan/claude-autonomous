#!/bin/bash
set -euo pipefail

# ── Configuration ──────────────────────────────────────────
PROJECT_DIR="$HOME/claude-autonomous/workspace"
STATE_DIR="$HOME/claude-autonomous/scripts/state"
LOG_DIR="$HOME/claude-autonomous/logs"
MAX_RUNTIME=10800                # 3 hours hard timeout
MAX_TURNS=50                     # ~50% of 5-hr window (~450 msgs avail)
MAX_BUDGET="25.00"               # Shadow cost per run (USD)
DAILY_BUDGET="25.00"             # Cumulative daily cap (USD)
# Budget rationale: Max 20x has ~900 msgs / ~220K tokens per
# 5-hour rolling window. 50% = ~450 msgs. At ~50 turns with
# high effort, each turn uses multiple API calls. $25 shadow
# cost cap provides headroom while staying within 50% target.
CONTAINER_NAME="claude-autonomous"

# ── Setup ──────────────────────────────────────────────────
TIMESTAMP=$(date +%Y-%m-%d_%H-%M-%S)
TODAY=$(date +%Y-%m-%d)
RUN_LOG="${LOG_DIR}/run_${TIMESTAMP}.json"
mkdir -p "$STATE_DIR" "$LOG_DIR"

# Prevent idle sleep for this script's lifetime
caffeinate -i -w $$ &

cleanup() {
    local exit_code=$?
    # Kill caffeinate background job
    kill %1 2>/dev/null || true
    # Stop any in-flight claude process in the container
    docker exec "$CONTAINER_NAME" pkill -f "claude" 2>/dev/null || true
    echo "{\"ts\":\"$TIMESTAMP\",\"exit\":$exit_code}" \
        >> "${STATE_DIR}/run_history.jsonl"
    echo "[$(date)] Cleaned up (exit code: $exit_code)"
}
trap cleanup EXIT
trap 'echo ""; echo "[$(date)] Interrupted by user"; exit 130' INT TERM

# ── Refresh OAuth credentials from host keychain ──────
CREDS=$(security find-generic-password -s "Claude Code-credentials" \
    -a "$(whoami)" -w 2>/dev/null || true)
if [[ -n "$CREDS" ]]; then
    docker exec "$CONTAINER_NAME" sudo bash -c \
        "echo '$CREDS' > /home/claude/.claude/.credentials.json \
        && chmod 600 /home/claude/.claude/.credentials.json \
        && chown claude:claude /home/claude/.claude/.credentials.json"
    echo "[$(date)] OAuth credentials refreshed from host keychain"
else
    echo "[$(date)] WARNING: Could not read OAuth credentials from keychain"
fi

# ── Budget gate ────────────────────────────────────────────
TODAYS_SPEND=$(grep "$TODAY" "${STATE_DIR}/cost_history.jsonl" \
    2>/dev/null | jq -s '[.[].cost] | add // 0' 2>/dev/null \
    | tr -d '[:space:]' || true)
TODAYS_SPEND=${TODAYS_SPEND:-0}

if (( $(echo "$TODAYS_SPEND >= $DAILY_BUDGET" | bc -l) )); then
    echo "[$(date)] Budget exceeded (\$$TODAYS_SPEND/\$$DAILY_BUDGET). Skipping."
    exit 0
fi

# ── Load previous state ───────────────────────────────────
PREV_STATE="First run. Read CLAUDE.md and tasks.json to begin."
[[ -f "${STATE_DIR}/last_run_state.json" ]] && \
    PREV_STATE=$(jq -r '.summary // "No summary available"' \
        "${STATE_DIR}/last_run_state.json")

GIT_LOG=$(cd "$PROJECT_DIR" && git log --oneline -10 \
    2>/dev/null || echo "No git history yet")
GIT_STATUS=$(cd "$PROJECT_DIR" && git status --short \
    2>/dev/null || echo "clean")

# ── Build the prompt ───────────────────────────────────────
# NOTE: The quality mandate and execution protocol below are
# the default autonomous prompt. Override or extend this by
# editing the PROMPT variable or sourcing from an external file.
read -r -d '' PROMPT << 'PROMPT_EOF' || true
You are an autonomous nightly development agent. Continue
building the app described in CLAUDE.md and tasks.json.

## Quality mandate
- Produce EXCELLENT work or stop. Do not produce mediocre
  work to fill turns.
- If you cannot make meaningful progress on a task after 2
  genuine attempts, STOP. Log the blocker in progress.txt
  and move to reflection phase.
- If you finish a task and fewer than 5 turns remain, enter
  reflection rather than starting a task you cannot finish
  properly.
- Never leave code in a broken state. If tests fail and you
  cannot fix them within 2 turns, revert to the last passing
  commit.

## Previous run summary
PREV_STATE_PLACEHOLDER

## Git state
Recent commits: GIT_LOG_PLACEHOLDER
Uncommitted: GIT_STATUS_PLACEHOLDER

## Execution protocol
1. Read CLAUDE.md for project context and standards
2. Read tasks.json - pick the next incomplete task
3. Plan your approach BEFORE writing code
4. Implement with tests. Run tests after every change.
5. If tests pass, commit immediately (don't batch commits)
6. If stuck: revert, log the blocker, move to reflection
7. REFLECTION PHASE (always do this, even if stopped early):
   - What worked? What didn't? What blocked you?
   - Update AGENTS.md with dated learnings
   - If a new pattern belongs in CLAUDE.md, add it
     (follow the meta-rules section in CLAUDE.md)
8. Write your JSON summary to stdout
PROMPT_EOF

# Inject dynamic state into prompt
PROMPT=${PROMPT//PREV_STATE_PLACEHOLDER/$PREV_STATE}
PROMPT=${PROMPT//GIT_LOG_PLACEHOLDER/$GIT_LOG}
PROMPT=${PROMPT//GIT_STATUS_PLACEHOLDER/$GIT_STATUS}

# ── Run Claude Code inside OrbStack container ──────────────
echo "[$(date)] Starting nightly run"
echo "  Budget spent today: \$$TODAYS_SPEND / \$$DAILY_BUDGET"
echo "  Max turns: $MAX_TURNS | Max budget: \$$MAX_BUDGET"

timeout ${MAX_RUNTIME} docker exec "$CONTAINER_NAME" \
    claude -p "$PROMPT" \
        --output-format json \
        --max-turns "$MAX_TURNS" \
        --max-budget-usd "$MAX_BUDGET" \
        --dangerously-skip-permissions \
        --model claude-opus-4-6 \
    > "$RUN_LOG" 2>> "${LOG_DIR}/stderr.log" || true

# ── Parse and persist results ──────────────────────────────
if [[ -s "$RUN_LOG" ]]; then
    COST=$(jq -r '.total_cost_usd // 0' "$RUN_LOG")
    SESSION=$(jq -r '.session_id // "unknown"' "$RUN_LOG")
    STATUS=$(jq -r '.subtype // "unknown"' "$RUN_LOG")
    RESULT=$(jq -r '.result // "No result"' "$RUN_LOG")

    # Save state for next run's prompt injection
    jq -n --arg d "$TIMESTAMP" --arg c "$COST" \
        --arg s "$SESSION" --arg r "$RESULT" \
        --arg st "$STATUS" \
        '{date:$d, cost:($c|tonumber), session:$s,
          status:$st, summary:($r|.[0:2000])}' \
        > "${STATE_DIR}/last_run_state.json"

    # Append to cumulative cost history
    echo "{\"date\":\"$TODAY\",\"cost\":$COST,\"session\":\"$SESSION\"}" \
        >> "${STATE_DIR}/cost_history.jsonl"

    echo "[$(date)] Run complete"
    echo "  Cost: \$$COST | Status: $STATUS | Session: $SESSION"
else
    echo "[$(date)] WARNING: No output from Claude Code"
fi

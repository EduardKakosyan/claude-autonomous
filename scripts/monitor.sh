#!/bin/bash
# Live monitoring of autonomous Claude Code runs
# Usage: ~/claude-autonomous/scripts/monitor.sh

WORKSPACE="$HOME/claude-autonomous/workspace"
STATE_DIR="$HOME/claude-autonomous/scripts/state"
LOG_DIR="$HOME/claude-autonomous/logs"
CONTAINER="claude-autonomous"

# Colors
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
DIM='\033[0;90m'
BOLD='\033[1m'
NC='\033[0m'

clear
echo -e "${BOLD}=== Claude Autonomous Monitor ===${NC}"
echo ""

while true; do
    # Move cursor to line 3 (after header)
    tput cup 2 0
    tput ed

    # ── Container status ─────────────────────────────────
    RUNNING=$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null || echo "false")
    if [[ "$RUNNING" == "true" ]]; then
        echo -e "${GREEN}Container:${NC} running"
    else
        echo -e "${RED}Container:${NC} stopped"
    fi

    # ── Claude process status ────────────────────────────
    CLAUDE_PID=$(docker exec "$CONTAINER" ps aux 2>/dev/null | grep -v grep | grep "claude" | awk '{print $2}' | head -1 || true)
    if [[ -n "$CLAUDE_PID" ]]; then
        echo -e "${GREEN}Claude:${NC}    active (PID $CLAUDE_PID)"
    else
        echo -e "${DIM}Claude:${NC}    idle"
    fi

    # ── Current run log size (proxy for activity) ────────
    LATEST_LOG=$(ls -t "$LOG_DIR"/run_*.json 2>/dev/null | head -1)
    if [[ -n "$LATEST_LOG" ]]; then
        LOG_SIZE=$(wc -c < "$LATEST_LOG" | tr -d ' ')
        LOG_NAME=$(basename "$LATEST_LOG")
        if [[ "$LOG_SIZE" -gt 0 ]]; then
            echo -e "${GREEN}Run log:${NC}   $LOG_NAME (${LOG_SIZE} bytes)"
        else
            echo -e "${YELLOW}Run log:${NC}   $LOG_NAME (in progress...)"
        fi
    fi

    # ── Last run result ──────────────────────────────────
    if [[ -f "${STATE_DIR}/last_run_state.json" ]]; then
        LAST_DATE=$(jq -r '.date // "unknown"' "${STATE_DIR}/last_run_state.json" 2>/dev/null)
        LAST_COST=$(jq -r '.cost // 0' "${STATE_DIR}/last_run_state.json" 2>/dev/null)
        LAST_STATUS=$(jq -r '.status // "unknown"' "${STATE_DIR}/last_run_state.json" 2>/dev/null)
        echo -e "${CYAN}Last run:${NC}  $LAST_DATE | \$$LAST_COST | $LAST_STATUS"
    fi

    # ── Spending today ───────────────────────────────────
    TODAY=$(date +%Y-%m-%d)
    SPEND=$(grep "$TODAY" "${STATE_DIR}/cost_history.jsonl" 2>/dev/null \
        | jq -s '[.[].cost] | add // 0' 2>/dev/null | tr -d '[:space:]' || echo "0")
    echo -e "${CYAN}Spend:${NC}     \$$SPEND today"

    # ── Git activity ─────────────────────────────────────
    echo ""
    echo -e "${BOLD}Recent commits:${NC}"
    cd "$WORKSPACE" 2>/dev/null && git log --oneline --since="12 hours ago" -10 2>/dev/null | while read -r line; do
        echo -e "  ${GREEN}●${NC} $line"
    done || echo -e "  ${DIM}(none in last 12h)${NC}"

    # ── Uncommitted + untracked changes ────────────────────
    echo ""
    echo -e "${BOLD}Working changes:${NC}"
    MODIFIED=$(cd "$WORKSPACE" 2>/dev/null && git diff --name-only 2>/dev/null)
    UNTRACKED=$(cd "$WORKSPACE" 2>/dev/null && git ls-files --others --exclude-standard 2>/dev/null)
    if [[ -n "$MODIFIED" || -n "$UNTRACKED" ]]; then
        echo "$MODIFIED" | grep -v '^$' | while read -r f; do
            echo -e "  ${YELLOW}~ $f${NC}"
        done
        echo "$UNTRACKED" | grep -v '^$' | while read -r f; do
            echo -e "  ${GREEN}+ $f${NC}"
        done
        TOTAL_FILES=$(echo -e "${MODIFIED}\n${UNTRACKED}" | grep -v '^$' | wc -l | tr -d ' ')
        echo -e "  ${DIM}($TOTAL_FILES files)${NC}"
    else
        echo -e "  ${DIM}(clean)${NC}"
    fi

    # ── Task progress ────────────────────────────────────
    if [[ -f "$WORKSPACE/tasks.json" ]]; then
        echo ""
        echo -e "${BOLD}Task progress:${NC}"
        TOTAL=$(jq '.tasks | length' "$WORKSPACE/tasks.json" 2>/dev/null || echo 0)
        DONE=$(jq '[.tasks[] | select(.status == "complete" or .status == "done")] | length' "$WORKSPACE/tasks.json" 2>/dev/null || echo 0)
        IN_PROG=$(jq '[.tasks[] | select(.status == "in_progress" or .status == "in-progress")] | length' "$WORKSPACE/tasks.json" 2>/dev/null || echo 0)
        PENDING=$((TOTAL - DONE - IN_PROG))

        # Progress bar
        if [[ $TOTAL -gt 0 ]]; then
            PCT=$((DONE * 100 / TOTAL))
            BAR_LEN=30
            FILLED=$((PCT * BAR_LEN / 100))
            EMPTY=$((BAR_LEN - FILLED))
            BAR=$(printf '%0.s█' $(seq 1 $FILLED 2>/dev/null) 2>/dev/null)
            SPACE=$(printf '%0.s░' $(seq 1 $EMPTY 2>/dev/null) 2>/dev/null)
            echo -e "  ${BAR}${SPACE} ${PCT}%  (${GREEN}${DONE} done${NC} / ${YELLOW}${IN_PROG} active${NC} / ${DIM}${PENDING} pending${NC})"
        fi

        # Show in-progress tasks
        jq -r '.tasks[] | select(.status == "in_progress" or .status == "in-progress") | "  ▶ \(.id): \(.title)"' "$WORKSPACE/tasks.json" 2>/dev/null | while read -r line; do
            echo -e "  ${YELLOW}$line${NC}"
        done
    fi

    # ── Live agent activity ────────────────────────────────
    LATEST_STREAM=$(ls -t "$LOG_DIR"/stream_*.jsonl 2>/dev/null | head -1)
    if [[ -n "$LATEST_STREAM" && -s "$LATEST_STREAM" ]]; then
        echo ""
        echo -e "${BOLD}Agent activity:${NC}"
        # Show last few tool uses and assistant messages
        tail -20 "$LATEST_STREAM" 2>/dev/null | while IFS= read -r line; do
            TYPE=$(echo "$line" | jq -r '.type // empty' 2>/dev/null)
            if [[ "$TYPE" == "assistant" ]]; then
                # Show tool use names
                TOOLS=$(echo "$line" | jq -r '.message.content[]? | select(.type=="tool_use") | .name' 2>/dev/null | tr '\n' ', ' | sed 's/,$//')
                if [[ -n "$TOOLS" ]]; then
                    echo -e "  ${CYAN}▸ Using: $TOOLS${NC}"
                fi
                # Show text output (truncated)
                TEXT=$(echo "$line" | jq -r '.message.content[]? | select(.type=="text") | .text' 2>/dev/null | head -2 | cut -c1-100)
                if [[ -n "$TEXT" ]]; then
                    echo -e "  ${DIM}$TEXT${NC}"
                fi
            elif [[ "$TYPE" == "result" ]]; then
                TURNS=$(echo "$line" | jq -r '.num_turns // "?"' 2>/dev/null)
                COST=$(echo "$line" | jq -r '.total_cost_usd // "?"' 2>/dev/null)
                echo -e "  ${GREEN}✓ Finished: $TURNS turns, \$$COST${NC}"
            fi
        done
    fi

    # ── Stderr tail ──────────────────────────────────────
    if [[ -f "$LOG_DIR/stderr.log" ]]; then
        RECENT_ERR=$(tail -3 "$LOG_DIR/stderr.log" 2>/dev/null | grep -v "^$")
        if [[ -n "$RECENT_ERR" ]]; then
            echo ""
            echo -e "${RED}Recent stderr:${NC}"
            echo "$RECENT_ERR" | while read -r line; do
                echo -e "  ${RED}$line${NC}"
            done
        fi
    fi

    echo ""
    echo -e "${DIM}Refreshing every 10s... (Ctrl+C to exit)${NC}"
    sleep 10
done

#!/usr/bin/env bash
# Auto-Dev orchestration — chains Hermes team agents like Claude Code's Agent tool
# Flow: architect → dev → qa → reviewer (optional ops for infra tasks)
# Each stage produces artifact → feeds into next
#
# Usage:
#   surrogate-orchestrate.sh "task description"
#   surrogate-orchestrate.sh --mode plan "task"     # architect only
#   surrogate-orchestrate.sh --mode yolo "task"     # full chain, no gates
set -u
set -a; source "$HOME/.hermes/.env" 2>/dev/null; set +a

MODE="auto"
TASK=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --mode) MODE="$2"; shift 2 ;;
        *) TASK="$*"; break ;;
    esac
done
[[ -z "$TASK" ]] && { echo "need task"; exit 2; }

# Colors
R=$'\033[0m'; B=$'\033[1m'; D=$'\033[2m'
CY=$'\033[36m'; GR=$'\033[32m'; YE=$'\033[33m'; MA=$'\033[35m'; RE=$'\033[31m'; GY=$'\033[90m'
BCY=$'\033[96m'

SESSION_ID=$(date +%s | tail -c 9)
WORKDIR="$HOME/.claude/state/orchestrate/$SESSION_ID"
mkdir -p "$WORKDIR"

echo "${BCY}${B}╭─ Auto-Dev Orchestration ─────────────────╮${R}"
echo "${BCY}${B}│${R} session: ${YE}$SESSION_ID${R}  mode: ${MA}$MODE${R}"
echo "${BCY}${B}│${R} cwd: ${D}$(pwd)${R}"
echo "${BCY}${B}╰──────────────────────────────────────────╯${R}"
echo "${B}▸ Task:${R} $TASK"
echo ""

# Helper: call surrogate agent with specific role + feed artifacts
call_agent() {
    local role="$1" prompt="$2" output_file="$3"
    echo "${CY}▶${R} ${B}$role${R} ${D}working...${R}"
    # Use surrogate CLI to run the role-based task
    local agent_prompt="[ROLE: $role]
$prompt

Output your work to $output_file using the \`write\` tool when done.
Previous artifacts available in: $WORKDIR/
CWD: $(pwd)"
    ~/.claude/bin/surrogate -p "$agent_prompt" 2>&1 | /usr/bin/head -50 | sed 's/^/  /'
    # Check if file written
    if [[ -f "$output_file" ]]; then
        echo "${GR}  ⎿ $role done → $(basename "$output_file") ($(wc -c < "$output_file") bytes)${R}"
        return 0
    else
        echo "${RE}  ⎿ $role: no output file written${R}"
        return 1
    fi
}

# ═══ Stage 1: ARCHITECT ═══
ARCH_OUT="$WORKDIR/1-architect-plan.md"
echo ""
echo "${MA}${B}═══ Stage 1/5: ARCHITECT${R} ${D}— decompose + plan${R}"
call_agent "architect" "
วิเคราะห์ task แล้วสร้าง plan ใน spec format:
1. Requirements (what / why)
2. Decomposition (steps needed)
3. Files to create/modify (with paths)
4. Test criteria
5. Rollback plan

Use \`read\`, \`glob\`, \`grep\` to understand current codebase first.
Task: $TASK
" "$ARCH_OUT"

if [[ "$MODE" == "plan" ]]; then
    echo ""
    echo "${B}▸ Plan-only mode — stopping after architect${R}"
    [[ -f "$ARCH_OUT" ]] && cat "$ARCH_OUT"
    exit 0
fi

# ═══ Stage 2: DEV ═══
DEV_OUT="$WORKDIR/2-dev-summary.md"
echo ""
echo "${MA}${B}═══ Stage 2/5: DEV${R} ${D}— implement code${R}"
call_agent "dev" "
Implement the architect's plan. Write actual code files using \`write\`/\`edit\` tools.

Architect plan at: $ARCH_OUT

After implementation, write summary (which files you created/modified) to output file.
Task: $TASK
" "$DEV_OUT"

# ═══ Stage 3: QA ═══
QA_OUT="$WORKDIR/3-qa-report.md"
echo ""
echo "${MA}${B}═══ Stage 3/5: QA${R} ${D}— test + verify${R}"
call_agent "qa" "
Test the implementation. Run:
- syntax check (python -c / node -c / go vet)
- existing tests if any
- write basic unit tests if missing

Dev summary: $DEV_OUT
Architect plan: $ARCH_OUT

Report test results to output file: pass/fail per check + findings.
Task: $TASK
" "$QA_OUT"

# ═══ Stage 4: OPS (if task mentions infra) ═══
if echo "$TASK" | /usr/bin/grep -iqE "deploy|docker|helm|k8s|terraform|cicd|ci/cd"; then
    OPS_OUT="$WORKDIR/4-ops-checklist.md"
    echo ""
    echo "${MA}${B}═══ Stage 4/5: OPS${R} ${D}— deploy + infra${R}"
    call_agent "ops" "
Review infrastructure aspects. Check:
- Dockerfile / helm chart / terraform validity
- Secrets / env var handling
- Resource limits
- Observability (metrics/logs/traces)

Dev summary: $DEV_OUT
Output to: $OPS_OUT
Task: $TASK
" "$OPS_OUT"
else
    echo ""
    echo "${GY}═══ Stage 4/5: OPS — skipped (not infra task)${R}"
fi

# ═══ Stage 5: REVIEWER ═══
REVIEW_OUT="$WORKDIR/5-review-verdict.md"
echo ""
echo "${MA}${B}═══ Stage 5/5: REVIEWER${R} ${D}— final gate${R}"
call_agent "reviewer" "
FINAL REVIEW GATE. Check all prior stages:
- Architect plan: $ARCH_OUT
- Dev implementation summary: $DEV_OUT
- QA report: $QA_OUT

Judge the work on:
1. Correctness vs requirements
2. Code quality (naming, no hallucinated imports, error handling)
3. Security (no leaked secrets, input validation)
4. Tests coverage
5. Match existing codebase style

Verdict: APPROVE / REWORK / REJECT
If REWORK — specify what to redo.

Output verdict + reasons to: $REVIEW_OUT
Task: $TASK
" "$REVIEW_OUT"

# ═══ Summary ═══
echo ""
echo "${BCY}${B}╭─ Session Complete ───────────────────────╮${R}"
echo "${BCY}${B}│${R} session: $SESSION_ID"
echo "${BCY}${B}│${R} artifacts: $WORKDIR/"
echo "${BCY}${B}╰──────────────────────────────────────────╯${R}"
ls -la "$WORKDIR/" 2>&1 | tail -n +2 | awk '{print "  " $9}' | grep -v '^  $'

# Show verdict + auto-commit if APPROVED
VERDICT_TEXT=""
if [[ -f "$REVIEW_OUT" ]]; then
    VERDICT_TEXT=$(grep -iE "verdict|APPROVE|REWORK|REJECT" "$REVIEW_OUT" | /usr/bin/head -3)
    echo ""
    echo "${B}▸ Final verdict:${R}"
    echo "$VERDICT_TEXT" | sed 's/^/  /'
fi

# Auto-commit when reviewer approves (ship code)
if echo "$VERDICT_TEXT" | grep -qi "APPROVE"; then
    echo ""
    echo "${GR}${B}▸ Reviewer approved — committing changes${R}"
    # Only commit if there are staged/unstaged changes
    if ! git -C "$(pwd)" diff --quiet 2>/dev/null || ! git -C "$(pwd)" diff --cached --quiet 2>/dev/null; then
        # Stage all changes in CWD
        git -C "$(pwd)" add -A 2>/dev/null
        # Build commit message from task + session
        COMMIT_MSG="feat: $(echo "$TASK" | head -c 72)

[surrogate auto-dev session $SESSION_ID]
[reviewed: APPROVE]"
        if git -C "$(pwd)" commit -m "$COMMIT_MSG" 2>&1 | tee -a "$WORKDIR/git-commit.log" | grep -q "master\|main\|\["; then
            COMMIT_HASH=$(git -C "$(pwd)" rev-parse --short HEAD 2>/dev/null)
            echo "${GR}  ✅ Committed: $COMMIT_HASH${R}"
        else
            echo "${YE}  ⚠ Nothing to commit (files already clean)${R}"
        fi
    else
        echo "${GY}  ○ No file changes to commit${R}"
    fi
elif echo "$VERDICT_TEXT" | grep -qi "REWORK"; then
    echo ""
    echo "${YE}${B}▸ Reviewer requested REWORK — re-running dev stage${R}"
    REWORK_NOTES=$(grep -A5 -i "REWORK" "$REVIEW_OUT" | /usr/bin/head -8)
    DEV_OUT2="$WORKDIR/2b-dev-rework.md"
    call_agent "dev" "
REWORK requested by reviewer. Fix the following issues:

$REWORK_NOTES

Original task: $TASK
Original implementation: $DEV_OUT
QA report: $QA_OUT

Fix the issues and write updated summary to output file.
" "$DEV_OUT2"
    echo "${D}  Rework complete — re-run $0 to go through QA + review again if needed${R}"
fi

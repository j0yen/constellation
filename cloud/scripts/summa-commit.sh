#!/usr/bin/env bash
# summa-commit.sh — auto-commit the ~/Notes vault (summa schema)
# node-local: runs only on the machine that holds the vault (carbon)
# Never force-pushes; push is guarded behind a remote-exists check.
set -euo pipefail

NOTES_DIR="${HOME}/Notes"
GIT="git -C ${NOTES_DIR}"

# ---- 1. Guard: vault must be a git repo ----------------------------------------
if ! ${GIT} rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "summa-commit: ${NOTES_DIR} is not a git repo — skipping (run PRD-summa-schema first)"
    exit 0
fi

# ---- 2. Guard: node eligibility -------------------------------------------------
if command -v wm-node >/dev/null 2>&1; then
    if ! wm-node should-run summa-commit >/dev/null 2>&1; then
        echo "summa-commit: wm-node says not this node's job — skipping"
        exit 0
    fi
fi

# ---- 3. Check for changes -------------------------------------------------------
changed=$(${GIT} status --porcelain | wc -l)
if [[ "${changed}" -eq 0 ]]; then
    echo "summa-commit: tree clean, nothing to commit"
    exit 0
fi

# ---- 4. Count ingests and answers from log.md since last commit -----------------
LOG_FILE="${NOTES_DIR}/log.md"
ingests=0
answers=0

if [[ -f "${LOG_FILE}" ]]; then
    # Get ISO timestamp of last commit (empty string if no commits yet)
    last_commit_ts=$(${GIT} log --format="%aI" -1 2>/dev/null || true)

    if [[ -n "${last_commit_ts}" ]]; then
        # Extract lines added after last commit timestamp by using git diff
        # Count lines in log.md that were added since last commit
        new_log_lines=$(${GIT} diff HEAD -- log.md 2>/dev/null | grep '^+' | grep -v '^+++' || true)
        ingests=$(echo "${new_log_lines}" | grep -ci 'ingest\|ingested\|added\|import' || true)
        answers=$(echo "${new_log_lines}" | grep -ci 'ask\|answer\|query\|question' || true)
    else
        # First commit — count all entries in log.md
        ingests=$(grep -ci 'ingest\|ingested\|added\|import' "${LOG_FILE}" 2>/dev/null || true)
        answers=$(grep -ci 'ask\|answer\|query\|question' "${LOG_FILE}" 2>/dev/null || true)
    fi
fi

# ---- 5. Stage and commit --------------------------------------------------------
${GIT} add -A

commit_msg="summa: ${changed} files changed (${ingests} ingests, ${answers} answers)"

${GIT} \
    -c user.name="Joe Yen" \
    -c user.email="jyen.tech@gmail.com" \
    commit -m "${commit_msg}"

echo "summa-commit: committed — ${commit_msg}"

# ---- 6. Push if remote exists ---------------------------------------------------
if remote_url=$(${GIT} remote get-url origin 2>/dev/null); then
    echo "summa-commit: pushing to ${remote_url}"
    ${GIT} push
    echo "summa-commit: push complete"
else
    echo "summa-commit: no remote configured — local commit only"
fi

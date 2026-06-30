#!/bin/bash
# Git cleanup script - checkout base branch, pull latest, delete merged feature branch
# Usage: git-cleanup-merged-branch.sh [--repo DIR] [feature-branch] [base-branch]
#   If no branches specified, uses current branch as feature and finds its base
#   --repo DIR  Run git in repository DIR (avoids a leading `cd`, which would
#               break the Bash(~/.claude/bin/*) permission match)

set -e  # Exit on error

# Parse an optional --repo flag from the front of the argument list, then cd in
# BEFORE any git command (including the `git branch --show-current` default).
if [ "${1:-}" = "--repo" ]; then
    REPO_DIR="$2"
    shift 2
    cd "$REPO_DIR" || { echo "Error: cannot cd into repo '$REPO_DIR'" >&2; exit 1; }
fi

FEATURE_BRANCH="${1:-$(git branch --show-current)}"
BASE_BRANCH="${2:-}"

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== Git Cleanup: Merged Branch ===${NC}"
echo "Feature branch: $FEATURE_BRANCH"

# Find base branch if not specified
if [ -z "$BASE_BRANCH" ]; then
    echo "Finding base branch for $FEATURE_BRANCH..."

    # Try git-find-base-branch first
    if [ -x ~/.claude/bin/git-find-base-branch ]; then
        BASE_BRANCH=$(~/.claude/bin/git-find-base-branch)
    else
        # Fallback: check common base branches
        for candidate in develop master main; do
            if git show-ref --verify --quiet refs/heads/$candidate; then
                if git merge-base --is-ancestor "$candidate" "$FEATURE_BRANCH" 2>/dev/null; then
                    BASE_BRANCH=$candidate
                    break
                fi
            fi
        done
    fi

    if [ -z "$BASE_BRANCH" ]; then
        echo -e "${RED}Error: Could not determine base branch${NC}"
        echo "Please specify manually: git-cleanup-merged-branch.sh $FEATURE_BRANCH <base-branch>"
        exit 1
    fi
fi

echo "Base branch: $BASE_BRANCH"

# Verify feature branch exists
if ! git show-ref --verify --quiet refs/heads/"$FEATURE_BRANCH"; then
    echo -e "${RED}Error: Branch '$FEATURE_BRANCH' does not exist${NC}"
    exit 1
fi

# Verify base branch exists
if ! git show-ref --verify --quiet refs/heads/"$BASE_BRANCH"; then
    echo -e "${RED}Error: Base branch '$BASE_BRANCH' does not exist${NC}"
    exit 1
fi

# Don't allow cleanup of base branch itself
if [ "$FEATURE_BRANCH" = "$BASE_BRANCH" ]; then
    echo -e "${RED}Error: Cannot cleanup base branch '$BASE_BRANCH'${NC}"
    exit 1
fi

# Warn if there are uncommitted changes
if ! git diff-index --quiet HEAD --; then
    echo -e "${YELLOW}Warning: You have uncommitted changes${NC}"
    read -p "Continue anyway? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

# Step 1: Checkout base branch
echo -e "\n${GREEN}Step 1: Checking out $BASE_BRANCH${NC}"
git checkout "$BASE_BRANCH"

# Step 2: Fetch latest changes and prune stale remote-tracking branches
echo -e "\n${GREEN}Step 2: Fetching latest changes${NC}"
git fetch --prune origin

# Step 3: Pull latest changes
echo -e "\n${GREEN}Step 3: Pulling latest $BASE_BRANCH${NC}"
git pull --prune origin "$BASE_BRANCH"

# Step 4: Delete feature branch (only if fully merged)
echo -e "\n${GREEN}Step 4: Deleting merged feature branch $FEATURE_BRANCH${NC}"

# Check if feature branch is fully merged
if git branch --merged "$BASE_BRANCH" | grep -q "^[* ]*$FEATURE_BRANCH$"; then
    git branch -d "$FEATURE_BRANCH"
    echo -e "${GREEN}✓ Successfully deleted local branch '$FEATURE_BRANCH'${NC}"

    # Try to delete remote branch if it exists
    if git ls-remote --exit-code --heads origin "$FEATURE_BRANCH" &>/dev/null; then
        echo -e "\n${YELLOW}Remote branch 'origin/$FEATURE_BRANCH' still exists${NC}"
        read -p "Delete remote branch? (y/N) " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            git push origin --delete "$FEATURE_BRANCH"
            echo -e "${GREEN}✓ Successfully deleted remote branch 'origin/$FEATURE_BRANCH'${NC}"
        fi
    fi
else
    echo -e "${RED}Error: Branch '$FEATURE_BRANCH' is not fully merged into '$BASE_BRANCH'${NC}"
    echo "Use 'git branch -D $FEATURE_BRANCH' to force delete (will lose unmerged changes!)"
    exit 1
fi

echo -e "\n${GREEN}=== Cleanup Complete ===${NC}"
echo "Current branch: $(git branch --show-current)"
echo "Latest commit: $(git log -1 --oneline)"

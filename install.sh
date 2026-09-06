#!/bin/bash
REPO_DIR="$(cd "$(dirname "$0")" && pwd)"

# Create ~/.claude if it doesn't exist
mkdir -p ~/.claude

# Symlink skills
if [ -L ~/.claude/skills ] || [ -e ~/.claude/skills ]; then
    echo "~/.claude/skills already exists. Remove it first if you want to reinstall."
else
    ln -sfn "$REPO_DIR/skills" ~/.claude/skills
    echo "Installed: ~/.claude/skills → $REPO_DIR/skills/"
fi

# Symlink agents directory
if [ -L ~/.claude/agents ] || [ -e ~/.claude/agents ]; then
    echo "~/.claude/agents already exists. Remove it first if you want to reinstall."
else
    ln -sfn "$REPO_DIR/agents" ~/.claude/agents
    echo "Installed: ~/.claude/agents → $REPO_DIR/agents/"
fi

# Symlink bin (helper scripts)
if [ -L ~/.claude/bin ] || [ -e ~/.claude/bin ]; then
    echo "~/.claude/bin already exists. Remove it first if you want to reinstall."
else
    ln -sfn "$REPO_DIR/bin" ~/.claude/bin
    echo "Installed: ~/.claude/bin → $REPO_DIR/bin/"
fi

# Symlink rules
if [ -L ~/.claude/rules ] || [ -e ~/.claude/rules ]; then
    echo "~/.claude/rules already exists. Remove it first if you want to reinstall."
else
    ln -sfn "$REPO_DIR/rules" ~/.claude/rules
    echo "Installed: ~/.claude/rules → $REPO_DIR/rules/"
fi

# Symlink global CLAUDE.md
if [ -L ~/.claude/CLAUDE.md ] || [ -e ~/.claude/CLAUDE.md ]; then
    echo "~/.claude/CLAUDE.md already exists. Remove it first if you want to reinstall."
else
    ln -sf "$REPO_DIR/claude-md/global.md" ~/.claude/CLAUDE.md
    echo "Installed: ~/.claude/CLAUDE.md → $REPO_DIR/claude-md/global.md"
fi

# Copy global settings (not symlink — Claude Code writes to this file)
if [ -e ~/.claude/settings.json ]; then
    echo "~/.claude/settings.json already exists. Remove it first if you want to reinstall."
else
    # Strip JSONC comments to produce valid JSON, and expand __HOME__ into the
    # real home directory. Values under "env" reach their subprocess as literal
    # strings — nothing expands `~` or `${HOME}` for them — so the placeholder
    # has to be resolved here, at install time, on the machine that has a $HOME.
    sed 's|//.*||' "$REPO_DIR/claude-md/settings-global.jsonc" | python3 -c "
import sys, json, os
config = json.load(sys.stdin)

def expand(value):
    if isinstance(value, str):
        return value.replace('__HOME__', os.path.expanduser('~'))
    if isinstance(value, list):
        return [expand(item) for item in value]
    if isinstance(value, dict):
        return {key: expand(item) for key, item in value.items()}
    return value

json.dump(expand(config), sys.stdout, indent=2)
print()
" > ~/.claude/settings.json
    echo "Installed: ~/.claude/settings.json (copied from settings-global.jsonc)"
fi

# Create toolkit.yaml if it does not exist
if [ ! -f ~/.claude/toolkit.yaml ]; then
    cat > ~/.claude/toolkit.yaml << 'EOF'
# Claude Code Toolkit sync configuration
# Run /sync-toolkit pull to update from source repos.
sources:
  - name: public
    repo: https://github.com/JanKeijzer/claude-code-toolkit.git
    branch: main
    install:
      skills: skills/
      agents: agents/
      claude-md: claude-md/global.md

  # Uncomment for private skills:
  # - name: imperial
  #   repo: git@github.com:imperial-automation/claude-toolkit-private.git
  #   branch: main
  #   install:
  #     skills: skills/

targets:
  skills: ~/.claude/skills
  agents: ~/.claude/agents
  claude-md: ~/.claude/CLAUDE.md

cache_dir: ~/.claude/toolkit-cache
EOF
    echo "Created ~/.claude/toolkit.yaml"
fi

# Create toolkit-proposals directory
mkdir -p ~/.claude/toolkit-proposals

# Create knowledge directory (user-owned, not symlinked — for lessons learned, reference docs, etc.)
mkdir -p ~/.claude/knowledge

#!/bin/bash
# Thin exec wrapper — the real implementation is hook-auto-approve-bash.py
# (real shlex-based tokenization; see that file and issue #12 for why the
# regex version this replaced was unreliable for compound commands).
exec python3 "$(dirname "${BASH_SOURCE[0]}")/hook-auto-approve-bash.py"

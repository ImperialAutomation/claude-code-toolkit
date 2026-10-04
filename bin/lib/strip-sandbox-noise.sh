#!/usr/bin/env bash
# strip-sandbox-noise.sh — drop the sandbox's cosmetic .gitmodules warning from
# git's stderr, and nothing else.
#
# Source this, then call git through `git_filtered` instead of `git`:
#
#     # shellcheck source=bin/lib/strip-sandbox-noise.sh
#     . "$(dirname "${BASH_SOURCE[0]}")/lib/strip-sandbox-noise.sh"
#     git_filtered commit -F "$TMPFILE"
#
# WHY THIS EXISTS
#
# Under the Claude Code sandbox, startup lays read-only bind-mounts of /dev/null
# over a handful of dotfiles in the working tree, .gitmodules among them — even
# when the file does not exist on the host. That is hardening, not a defect: it
# blocks submodule command injection (`url = ext::sh -c ...`). It stays.
#
# The side effect is that nearly every git call carries one extra line:
#
#     warning: unable to access '<repo>/.gitmodules': Permission denied
#
# Exit code stays 0 and nothing is blocked, so the line is purely cosmetic. But
# it contains the words `warning`, `unable to access` and `Permission denied`,
# so an agent reading the output investigates it — and the trigger to discover
# it is ignorable is seeing it, which means the investigation has already
# started before any documentation is reached. One user re-diagnosed this at
# least five times across months despite a note saying not to. Documentation is
# advice; this needs to be enforced, which is why it is code and not a README.
#
# Already tried and ruled out — do not revisit:
#   - allowRead/allowWrite with `**/.gitmodules` does not lift the mount. Those
#     keys drive permission and deny rules, not the physical runtime mounts laid
#     at sandbox startup. Tested and disproven.
#   - Removing the file does not work and has no point: `rm` reports `Device or
#     resource busy`, and on the host the file usually does not exist at all.
#   - Git has no switch that suppresses just this warning.
#
# THE FILTER IS DELIBERATELY NARROW
#
# The real risk here is matching too much, not too little. A broad `^warning:`
# filter would later hide something that matters — a detached HEAD, an aborted
# merge, a failing hook — and that is a worse outcome than the noise it removes.
# So the pattern requires all three parts of the exact message: the `warning:`
# severity, a quoted path ending in `.gitmodules`, and `Permission denied` as
# the reason. An `error:` about the same path, an I/O error on the same path,
# and a permission problem on any other path all pass through untouched.
# Rather one line too many through than one too few.

# Anchored at both ends, so the line must be this message and nothing more.
# The path is free-form because worktrees live anywhere, but it has to end in
# .gitmodules, and the reason has to be the permission error.
_SANDBOX_NOISE_RE="^warning: unable to access '[^']*\.gitmodules': Permission denied$"

# Run git with that one line removed from stderr.
#
# stderr stays on stderr: the message arrives there, and routing it through
# stdout would change the meaning of the output for callers that separate the
# two. So the streams are swapped around a pipe and swapped back — git's stderr
# goes through grep and returns to fd 2, while fd 1 is never read, let alone
# filtered. Binary output (`git show`, `git archive`) and data that merely looks
# like the warning both pass through byte for byte.
#
# A process substitution would be the shorter spelling, but it is reaped
# asynchronously and does not reliably set `$!`, so there is no way to wait for
# the filter to flush; a surviving warning could then land after output that
# logically precedes it. A pipeline is synchronous, and PIPESTATUS still carries
# git's own status.
#
# The exit status reported is git's own. A naive pipeline would report the
# filter's status instead, turning every git failure behind this helper silently
# green — which would make a cosmetic fix into a real bug.
git_filtered() {
    local -a pipe_status

    # fd 3 holds the function's real stdout for the duration of the pipeline.
    # Inside a pipeline fd 1 IS the pipe, so git's stdout has to be routed out
    # through fd 3 to reach the caller unread; its stderr takes fd 1 into grep,
    # and grep's surviving lines are put back onto fd 2 where they belong.
    #
    # grep exits 1 when it prints nothing, so its status is meaningless here;
    # reading PIPESTATUS[0] rather than `$?` reports git's own status.
    #
    # `|| true` is load-bearing, not defensive noise. The wrappers run under
    # `set -e -o pipefail`, and grep's status-1-on-no-output would otherwise make
    # the pipeline status 1, which `set -e` treats as fatal — aborting the script
    # at the call site on a SUCCESSFUL git call. PIPESTATUS is captured before
    # `|| true` resolves, so git's real status still survives.
    # `|| true` sits INSIDE the second pipeline stage, not around the group: at
    # group level it would also mask git's status before PIPESTATUS is read, and
    # every git failure would report success. Here it only neutralises grep.
    { { git "$@" 2>&1 1>&3; } | { grep -v -E "$_SANDBOX_NOISE_RE" >&2 || true; }; } 3>&1
    pipe_status=("${PIPESTATUS[@]}")

    return "${pipe_status[0]}"
}

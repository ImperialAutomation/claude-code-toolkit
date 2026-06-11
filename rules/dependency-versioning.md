---
description: How to choose, pin, and age dependency versions safely across any ecosystem
---

# Dependency Versioning

Four principles, ecosystem-independent. Each maps to a concrete mechanism per
package manager — uv and npm are filled in as worked examples; for any other
ecosystem (composer, cargo, go modules, maven, bundler…), find the equivalent
lever and apply the same principle. The principle is the rule; the tool is just
how you express it.

## 1. Run an exact, reviewed tree

The tree you audit must equal the tree you ship, and it changes only when a human
deliberately re-resolves it. Three levers:

- **Commit the lockfile** — it is the reproducibility source of truth. CI must
  install *strictly from it* and fail on a stale lock, so "forgot to re-lock"
  drift cannot ship.
- **Pin exact versions** for direct deps — `==`/exact, not `>=`/range, so a new
  dep is deliberate rather than silently drifting on the next resolve.
- **Pin transitively when needed** — a transitive-only CVE is fixed by forcing a
  safe version of the sub-dependency, without waiting for every parent to update.

| Lever | uv | npm | Other (find the equivalent) |
|---|---|---|---|
| Lockfile + strict install | `uv.lock` + `uv sync --locked` | `package-lock.json` + `npm ci` | `composer.lock`, `Cargo.lock`, `go.sum`, `Gemfile.lock` — commit it, install strict |
| Exact direct pins | `add-bounds = "exact"` | exact versions in `package.json` | `composer require pkg:1.2.3`, `=` in `Cargo.toml`, etc. |
| Transitive pin | constraint / override entry | `overrides` | composer `conflict`/`replace`, cargo `[patch]`, go `replace`, gem `force` |
| Pin the resolver itself | `required-version` | `engines` (node/npm floor) | lock the toolchain version however the ecosystem allows |

**Safe-but-old, pinned, is not debt.** A pinned version that is old but carries
no known CVE is not a compounding liability. A reactive audit gate (CVE scan on
every PR) is the security backstop — so security is covered without chasing every
release. Version *currency* is a separate, optional concern for deliberate
upgrade sprints, never a standing security obligation.

## 2. Wait out the zero-day window (cooldown)

A freshly published release — *including a security fix* — can carry a
just-introduced supply-chain compromise (cf. the `xz` backdoor, which shipped
inside an ordinary-looking release). So every version that enters the tree waits
N days (14 is a sound default) after publication, letting the community surface a
bad release first.

The cooldown can act at **two different points** — know which one your tool gives
you, because they cover different things:

| | Resolve-time cooldown | PR-time cooldown |
|---|---|---|
| **Acts at** | every resolve/lock operation | only when the update bot opens a PR |
| **Covers** | all deps incl. transitive + manual locks | versions the bot proposes |
| **Example** | uv `exclude-newer = "14 days"` (self-rolling, stored in lock) | Dependabot/Renovate `cooldown` block |
| **Gap** | — | a *manual* `install <pkg>@latest` bypasses it entirely |

**npm (and most ecosystems) have no resolve-time cutoff** — only the update-bot's
PR-time cooldown. uv is the exception with `exclude-newer`. Where only PR-time
exists, document the gap: a manual latest-install within the window is uncovered
by the cooldown (though still caught by the reactive audit gate if it has a known
advisory). Mitigation is procedural — let the bot channel propose upgrades; don't
hand-pull `@latest` for production deps. If a tool gains a resolve-time analogue,
adopt it to close the gap.

## 3. A security label is not proof of safety

**A CVE fix does not override the cooldown.** When a security-labelled release
lands *inside* the cooldown window, keep the older (still-vulnerable) version and
**time-box** the CVE as an accepted exception until the fix leaves the cooldown —
do not override the window to pull the fix early.

The instinct is "it's a *security* fix, surely we want it now." But the cooldown
exists precisely because a security-labelled release is *not* vetted-safe in its
first days — a release claiming to fix a CVE is no more reviewed than any other
(`xz` again). Overriding the cooldown for the label defeats the one control that
guards against a compromised "fix": you would trade a known, bounded,
often-unreachable vulnerability for an unknown supply-chain risk in fresh code.
The known CVE is the lesser, *measurable* risk — accept it for the remaining
cooldown days.

How: add a **time-boxed** exception whose expiry is the date the fix leaves the
cooldown (publish date + N days). On expiry the next resolve/PR picks up the
now-aged fix and the exception is removed — the gate goes green on the real fix,
not on an override.

Distinguish this from the **no-fix** case (no fixed version exists at all), which
needs a reachability decision (resolve if reachable; accept permanently only if
the vulnerable path is proven unreachable):

| Situation | Rule | Acceptance |
|---|---|---|
| Fix exists but is **within cooldown** | wait it out | time-boxed to cooldown end |
| **No fix**, path proven unreachable | accept | permanent + documented reachability |
| **No fix**, reachability uncertain | accept under clock | time-boxed (90d default) |
| **No fix**, path reachable & needed | resolve or escalate | do **not** accept |

## 4. Record the reasoning, not just the config

The config files (lockfile, bot config, exception list) enforce the *what*. Keep
a short policy doc for the *why* — why a version is pinned, why a CVE was
time-boxed vs accepted permanently, why you waited out a fix. The reasoning is
what a future reader (or you, in six months) cannot reconstruct from the config
alone. Point that doc at the enforcement files; never duplicate the mechanism.

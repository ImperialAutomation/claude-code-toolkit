# Review GitHub App runbook

Agents act on GitHub as your own account, and a PR author cannot approve or
request changes on their own PR. A review therefore needs a second identity:
one private GitHub App per owner account (your personal account, and each
organization such as `ImperialAutomation`). `bin/gh-app-token.sh` picks the app
of a repo's owner, requests an installation token limited to that one
repository and runs a command with it:

```bash
~/.claude/bin/gh-app-token.sh --repo <owner>/<repo> -- gh pr review 123 --approve --body "..."
```

This runbook covers setting up, using and maintaining those apps. Do steps 1
to 4 once per owner account. Nothing is configured per project beyond installing the app
on the repository.

Below, `<owner>` is the account login exactly as it appears in
`<owner>/<repo>` (for example `ImperialAutomation`), and `<you>` is your
personal login.

## 1. Register the app

Organization apps need an organization owner (or a GitHub App manager of that
organization).

1. Open the "New GitHub App" form:
   - personal account: <https://github.com/settings/apps/new>
     (Settings → Developer settings → GitHub Apps → New GitHub App)
   - organization: `https://github.com/organizations/<owner>/settings/apps/new`
     (organization Settings → Developer settings → GitHub Apps → New GitHub App)
2. **GitHub App name:** `<owner>-review`, lowercase (for example
   `imperialautomation-review`). Names are unique across GitHub; if it is
   taken, add a suffix. Reviews will show as `<app-name>[bot]`.
3. **Description:** optional; it shows only on the app's own page. Leave it
   empty or write one line on what the app is for.
4. **Homepage URL:** required but unused; the URL of the account
   (`https://github.com/<owner>`) is fine.
5. **Identifying and authorizing users** and **Post installation:** leave the
   defaults. **Expire user authorization tokens** may be checked by default;
   leave it as it is, it concerns user tokens, which the app never uses. Keep
   the redirect URI and setup URL empty and every other box unchecked.
6. **Webhook:** uncheck **Active**. The app receives no events.
7. **Repository permissions** (everything else stays "No access"):

   | Permission | Access | Why |
   |---|---|---|
   | Metadata | Read-only | mandatory; GitHub sets it |
   | Contents | Read-only | read the diff and files under review |
   | Pull requests | Read and write | post reviews and review comments |
   | Issues | Read and write | add the `needs-human` label |

   No organization or account permissions.
8. **Where can this GitHub App be installed?** Choose **Only on this account**.
9. Click **Create GitHub App**.
10. On the app's **General** page, note the **App ID** (a number, under
    "About"). This is the value for `app-id`, not the Client ID, although the
    page suggests the Client ID also works for installation tokens.
11. In the app's left sidebar, open **Credentials**, tab **Key pairs**, and
    click **New key**. (The tab **Client secrets** next to it is for OAuth;
    leave it alone.) The browser downloads
    `<app-name>.<date>.private-key.pem` to its download directory. This file
    is the only copy; GitHub keeps just the public half. Store it right away
    (step 3).

## 2. Install the app

1. On the app's settings page, choose **Install App** in the left sidebar,
   then **Install** next to the owner account.
2. Choose the repositories:
   - **All repositories:** every current and future repo of the owner. Least
     upkeep.
   - **Only select repositories:** pick the repos the review agent works on.
     Each new repo has to be added later.

   One key serves every repository in the installation, including repos added
   later: a leaked key reaches all of them (each token is still limited to one
   repo, but the key can mint a token for any). A selection keeps only the
   repos you never add out of reach. Adding a repo needs no new key.
3. Click **Install**.

**Adding a repository later** (only for "Only select repositories"):

- personal account: Settings → Applications → Installed GitHub Apps →
  `<app-name>` → **Configure**
- organization: organization Settings → Third-party Access → GitHub Apps →
  `<app-name>` → **Configure**

Under **Repository access**, add the repo and click **Save**.

## 3. Store the credentials

Per owner, outside every repository: a directory with mode 700 holding two
files with mode 600.

```bash
install -d -m 700 ~/.config/github-apps ~/.config/github-apps/<owner> ~/.config/github-apps/<owner>/review
install -m 600 <download-dir>/<app-name>.<date>.private-key.pem ~/.config/github-apps/<owner>/review/private-key.pem
printf '%s\n' <app-id> > ~/.config/github-apps/<owner>/review/app-id
chmod 600 ~/.config/github-apps/<owner>/review/app-id
rm <download-dir>/<app-name>.<date>.private-key.pem
```

`<download-dir>` is wherever the browser saved the key (often `~/Downloads`).
Back the key up, for example in a password manager, before the `rm` if you
want a copy; without one, a lost key is replaced by generating a new one.

The directory name must be spelled exactly as the owner appears in
`--repo <owner>/<repo>`, including case. The result:

```
~/.config/github-apps/
├── <you>/review/{app-id,private-key.pem}
└── ImperialAutomation/review/{app-id,private-key.pem}
```

Never copy the key into a repository, a project `.env` or a chat. On another
machine, repeat this step with a key generated for that machine (see
"Rotate the key"), rather than copying the file across.

## 4. Check the setup

For one repo of each owner where the app is installed:

```bash
~/.claude/bin/gh-app-token.sh --repo <owner>/<repo> -- gh api repos/<owner>/<repo> --jq .full_name
```

It prints `<owner>/<repo>` and exits 0. Otherwise the message names the
cause:

| Message | Cause | Fix |
|---|---|---|
| `no GitHub App for owner <owner>: ... app-id is missing or unreadable` (or `private-key.pem`) | No credentials for that owner, or the directory is spelled differently from `--repo` | Step 3; check the case of `<owner>` |
| `cannot sign the JWT with ...: not a valid RSA private key` | `private-key.pem` is not the downloaded key (wrong file, truncated, edited) | Store the downloaded `.pem` again, or generate a new key |
| `the GitHub App of <owner> (app <id>) is not installed on <owner>/<repo>, or the repository does not exist` | The app is not installed on the account, or the repo is not in its selection; or a typo in `--repo` | Step 2, "Adding a repository later" |
| `GitHub rejected the JWT of <owner>'s app (...)` mentioning `exp`/`iat` | The system clock is off by more than a minute | `timedatectl` should say `System clock synchronized: yes`; enable NTP |
| `GitHub rejected the JWT of <owner>'s app (...)`, any other message | `private-key.pem` belongs to another app, the key was deleted on GitHub, or `app-id` holds the wrong number (for example the Client ID) | Compare `app-id` with the App ID on the app's General page; generate a new key if needed |
| `GitHub refused an installation token for <owner>/<repo> (HTTP 403)` or `GitHub answered HTTP 403 ...`, mentioning `suspended` | The installation is suspended | "Suspend the app" below, to unsuspend |
| `gh` itself answers `Resource not accessible by integration` (HTTP 403) | The token works, but the app lacks a permission for that call | Step 1, permissions table; then "Change the permissions" below |
| `GitHub unreachable` | No network, or api.github.com is down | Retry |

## 5. Use

Every review under the app comes from `/pre-merge`; its verdict helper
(`pre-merge-verdict.py`) picks `APPROVE`, `BLOCKING` or `HUMAN`.

| Call | What happens |
|---|---|
| `/pre-merge <PR>` | Report only, nothing written to GitHub. Check out the PR's head branch first |
| `/pre-merge <PR> --post` | The same report, then one review under the app (`pre-merge-post.py`) |
| `/queue-run`, Step 4c | After the loop opens a PR, a reviewer sub-agent runs `/pre-merge <PR> --post`. A `BLOCKING` review gets one fix round and one re-review |

The review shows as `<app-name>[bot]`. Its body opens with
`/pre-merge verdict: <verdict>`, then the gate report. Findings on a diff line
are inline comments, the rest are listed in the body; MEDIUM and LOW findings
are listed under every verdict. You always merge yourself.

| Verdict | Review event and labels | What you do |
|---|---|---|
| `APPROVE` | `APPROVE` | Read it and merge, or post what should change and hand it back |
| `BLOCKING` | `REQUEST_CHANGES`; from `/queue-run`, `needs-human` on the issue when the re-review is still `BLOCKING` | Fix it yourself, or hand it back: the review is the input |
| `HUMAN` | `COMMENT` with question, options and recommendation on top; `needs-human` on the PR and every linked issue | Post your decision as a PR or issue comment, remove `needs-human` from the PR and the issue, then hand it back or act on it yourself |
| not posted | none; from `/queue-run`, `agent-pr` and `needs-human` on the issue, the error in its comment | Fix the cause (step 4 table), remove `needs-human` and run `/pre-merge <PR> --post`; never post as your own account |

Hand back an agent PR (its issue has `agent-pr`) by adding `agent-rework` to
the issue once it has no `needs-human`: the next `/queue-run` iteration runs a
fix round on the review input posted since its last round (the app's reviews
count), then a re-review. Without new input it escalates instead. See "Back
to the loop after a review (#300)" in `docs/escalation-list.md`.

## 6. Maintain

### Rotate the key

1. App settings → **Credentials** → **Key pairs** → **New key**. The app now
   has two valid keys.
2. Store the new key over `private-key.pem` (step 3, the `install -m 600` line).
3. Run the check (step 4).
4. Delete the old key under **Key pairs**. Its fingerprint is listed there;
   compare it with `openssl rsa -in <old.pem> -pubout -outform DER | openssl sha256 -binary | openssl base64`.

### Change the permissions

App settings → **Permissions & events** → change the access → **Save
changes**. A banner then says the app "was updated", but that is not the end:

- **More access** (for example Contents from Read-only to Read and write) must
  be accepted on the installation before tokens get it. Open the installation
  **Configure** page (step 2, "Adding a repository later"), accept the new
  permissions and confirm with your passkey or password. Until then every token
  still carries the old permissions, without an error.
- **Less access** takes effect at once; nothing to accept.

The **Configure** page lists the permissions the installation actually has
(for example "Read and write access to code").

### Remove a repository from the installation

Installation **Configure** page (step 2, "Adding a repository later") → under
**Repository access**, remove the repo and **Save**. From then on the script
answers "not installed" for that repo. With "All repositories", switch to
"Only select repositories" first.

### Suspend the app in an emergency

If the key may have leaked or the app is acting wrongly:

1. Installation **Configure** page → **Danger zone** → **Suspend**. Every
   installation token stops working immediately; the app can do nothing until
   it is unsuspended (same place).
2. If the key leaked: app settings → **Credentials** → **Key pairs** → delete every key, so
   no new JWT can be signed. Then generate and store a new key (step 3) before
   unsuspending.

Installation tokens live for one hour at most, and `gh-app-token.sh` keeps none
on disk; deleting the key and suspending the installation together close every
route.

### Add a new owner account

Steps 1 to 4 for that account. No code or configuration change: the script
finds the app by the owner in `--repo`.

## Branch protection: does the app's approval count?

**Result (2026-11-12, issue #291): only with `Contents: Read and write`.**
With the permissions from step 1 (`Contents: Read-only`) the app's approval
does **not** count toward a classic branch protection rule that requires one
approving review. With `Contents: Read and write`, accepted on the installation,
it does.

| App permission (Contents) | After the app's `APPROVE` |
|---|---|
| Read-only | `REVIEW_REQUIRED` / `BLOCKED` |
| Read and write, saved but not yet accepted on the installation | `REVIEW_REQUIRED` / `BLOCKED` (tokens still read-only) |
| Read and write, accepted | `APPROVED` / `CLEAN` |

The review itself is posted in every case and shows as `APPROVED` by
`<app-name>[bot]`. Not tested: repository rulesets (only the classic rule).

**Decision (#288, D5): the apps stay on `Contents: Read-only`.** Write access
would let an app token push to every repo of the installation; a reviewer
that cannot write stays independent of the fix sub-agent, the only writer. No
repo requires approvals today, and a human merges every PR. So the app's
`APPROVE` does not satisfy a required-approvals rule: a repo with that rule
needs an approval from another person, an admin merge (`gh pr merge --admin`,
only when the rule allows bypassing), or a new issue that revisits D5.

Procedure, to repeat the test, on a throwaway repo under your personal account
(public, because branch protection on a private repo needs a paid plan):

1. Create the repo and a PR as yourself, from a scratch directory such as
   `/tmp`:
   ```bash
   gh repo create <you>/review-app-spike --public --add-readme --clone
   git -C review-app-spike switch -c spike
   git -C review-app-spike commit --allow-empty -m "spike: app approval"
   git -C review-app-spike push -u origin spike
   env -C review-app-spike gh pr create --fill
   ```
2. Install your personal app on `<you>/review-app-spike` (step 2, "Adding a
   repository later"; nothing to do with "All repositories").
3. Protect `main`: repo **Settings** → **Branches** → **Add classic branch
   protection rule** (a borderless link next to the **Add branch ruleset**
   button), pattern `main`, check **Require a pull request before
   merging** with **Require approvals: 1**, and **Do not allow bypassing the
   above settings** (otherwise your admin rights hide the result). **Create**.
4. Before the review:
   ```bash
   gh pr view 1 --repo <you>/review-app-spike --json reviewDecision,mergeStateStatus
   ```
   Expect `"reviewDecision":"REVIEW_REQUIRED"` and `"mergeStateStatus":"BLOCKED"`.
5. Approve as the app:
   ```bash
   ~/.claude/bin/gh-app-token.sh --repo <you>/review-app-spike -- gh pr review 1 --repo <you>/review-app-spike --approve --body "spike: app approval"
   ```
6. After the review, run the command from step 4 again.
   - `"reviewDecision":"APPROVED"` and `"mergeStateStatus":"CLEAN"`: the
     app's approval **counts**.
   - Still `REVIEW_REQUIRED` / `BLOCKED`: it **does not count**. The PR page
     shows the review by `<app-name>[bot]` but the merge box still asks for an
     approval.
7. To test another permission, change it ("Change the permissions" above),
   approve again and measure again. Set the permissions back afterwards.
8. Remove the repo: its **Settings** → **Danger zone** → **Delete this
   repository**, and the local clone.

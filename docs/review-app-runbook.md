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

This runbook covers setting up and maintaining those apps. Do the steps once
per owner account. Nothing is configured per project beyond installing the app
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
3. **Homepage URL:** required but unused; the URL of the account
   (`https://github.com/<owner>`) is fine.
4. **Identifying and authorizing users:** leave everything empty and unchecked.
5. **Webhook:** uncheck **Active**. The app receives no events.
6. **Repository permissions** (everything else stays "No access"):

   | Permission | Access | Why |
   |---|---|---|
   | Metadata | Read-only | mandatory; GitHub sets it |
   | Contents | Read-only | read the diff and files under review |
   | Pull requests | Read and write | post reviews and review comments |
   | Issues | Read and write | add the `needs-human` label |

   No organization or account permissions.
7. **Where can this GitHub App be installed?** Choose **Only on this account**.
8. Click **Create GitHub App**.
9. On the app's **General** page, note the **App ID** (a number, under
   "About"). This is the value for `app-id`, not the Client ID.
10. Under **Private keys**, click **Generate a private key**. The browser
    downloads `<app-name>.<date>.private-key.pem`. This file is the only copy;
    GitHub keeps just the public half. Store it right away (step 3).

## 2. Install the app

1. On the app's settings page, choose **Install App** in the left sidebar,
   then **Install** next to the owner account.
2. Choose the repositories:
   - **All repositories:** every current and future repo of the owner. Least
     upkeep.
   - **Only select repositories:** pick the repos the review agent works on.
     Each new repo has to be added later.
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
install -m 600 ~/Downloads/<app-name>.<date>.private-key.pem ~/.config/github-apps/<owner>/review/private-key.pem
printf '%s\n' <app-id> > ~/.config/github-apps/<owner>/review/app-id
chmod 600 ~/.config/github-apps/<owner>/review/app-id
rm ~/Downloads/<app-name>.<date>.private-key.pem
```

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
| `gh` itself answers `Resource not accessible by integration` (HTTP 403) | The token works, but the app lacks a permission for that call | Step 1, permissions table; after changing permissions, accept them on the installation (GitHub asks the owner) |
| `GitHub unreachable` | No network, or api.github.com is down | Retry |

## 5. Maintain

### Rotate the key

1. App settings → **Private keys** → **Generate a private key**. The app now
   has two valid keys.
2. Store the new key over `private-key.pem` (step 3, the `install -m 600` line).
3. Run the check (step 4).
4. Delete the old key under **Private keys**. Its fingerprint is listed there;
   compare it with `openssl rsa -in <old.pem> -pubout -outform DER | openssl sha256 -binary | openssl base64`.

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
2. If the key leaked: app settings → **Private keys** → delete every key, so
   no new JWT can be signed. Then generate and store a new key (step 3) before
   unsuspending.

Installation tokens live for one hour at most, and `gh-app-token.sh` keeps none
on disk; deleting the key and suspending the installation together close every
route.

### Add a new owner account

Steps 1 to 4 for that account. No code or configuration change: the script
finds the app by the owner in `--repo`.

## Branch protection: does the app's approval count?

**Status: not yet tested.** The result goes here and on issue #291.

The question: does an `APPROVE` review from the app satisfy a branch protection
rule that requires approving reviews? GitHub counts approvals from accounts with
write access; the app has `Contents: Read-only`, so this is not obvious. A
negative result is recorded, not worked around: #288 decides what follows.

Procedure, on a throwaway repo under your personal account (public, because
branch protection on a private repo needs a paid plan):

1. Create the repo and a PR as yourself:
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
   protection rule**, pattern `main`, check **Require a pull request before
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
7. Record the result on issue #291 (the two `gh pr view` outputs and one
   sentence) and in this section, replacing "not yet tested".
8. Remove the repo: its **Settings** → **Danger zone** → **Delete this
   repository**.

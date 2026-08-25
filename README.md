# Masteorion DotFiles

Dotfiles that work across a personal Mac and several client machines **without any
client ever seeing another client's configuration**.

## The idea

This repository is **neutral**. It is byte-identical on every machine and contains no
client name, no work email, and no vault name. Ever.

Everything job-specific lives in that job's own password-manager vault and is pulled
down at install time into machine-local files that git never sees:

```
LAYER 1  ~/.dotfiles          committed, neutral, identical everywhere
LAYER 2  ~/.dotfiles-local    gitignored, mode 700, fetched from that machine's vault
```

Isolation is enforced by vault access control, not by discipline. Revoke the vault and
the configuration becomes unrecoverable on that machine.

> Why not a branch or a sparse checkout per client? Because `git clone` ships the whole
> object database. Sparse checkout filters the *working tree*, not `.git` — one
> `git log --all -p` and everything is visible. Filtering is not isolation.

Different jobs can use different password managers. **1Password** and **Bitwarden** are
both supported, including two separate 1Password accounts on the same machine.

## Install

```sh
git clone https://github.com/AndresMorelos/.dotfiles ~/.dotfiles
cd ~/.dotfiles
./install.sh
```

This repository is public **on purpose**. It has to be cloneable from a client
machine that holds none of your personal credentials, and it can be, because the
isolation never depended on the repo being private — it depends on client
configuration never entering the repo in the first place.

What is public here is the *shape* of the setup: package lists, shell config, and the
names of a few personal 1Password vaults. A vault name grants nothing without the
account, secret key and master password. What is never here: any work email, any client
name, any key, any token.

On a brand-new Mac that is all you need. `install.sh` installs the Xcode Command Line
Tools, Homebrew, every package, **and your password manager's app and CLI** — you never
have to install `op` or `bw` yourself.

It then asks whether this is a personal or a client machine and which password manager
to use, and stores the answer in `~/.config/dotfiles/config` (outside the repo).

Signing in to the password manager and enabling its SSH agent is the one step a script
cannot do for you. The installer pauses, tells you exactly which toggles to flip, and
waits. If you skip it, the rest of the setup still completes and it tells you to run
`./install.sh --sync-overlay` when you are ready.

## Commands

| Command | What it does |
|---|---|
| `./install.sh` | Full bootstrap |
| `./install.sh --link` | Relink dotfiles only. Fast, no network, no vault |
| `./install.sh --update` | Pull, relink, re-sync overlay, update all packages |
| `./install.sh --sync-overlay` | Re-fetch this machine's config from its vault |
| `./install.sh --adopt` | Inspect a hand-configured Mac and adopt what it already has |
| `./install.sh --doctor` | Profile, links, packages, and a repo neutrality scan |
| `./install.sh --show-signing-key` | Print the signing key and where to register it |
| `./install.sh --purge-overlay` | Erase all machine-local config. For handing a laptop back |
| `./install.sh --dump` | Snapshot current Homebrew state to `Brewfile.new` |

Package groups: `dev`, `productivity`, `macos`, `streaming`, `fonts`.
The base `Brewfile` always applies; groups are optional on top of it.

```sh
./install.sh --packages dev,macos        # only these
./install.sh --skip-packages streaming   # everything except these
```

## Adopting a machine that already exists

On a Mac you configured by hand years ago, run this before anything else:

```sh
./install.sh --adopt
```

It reads the machine instead of interrogating you:

- the git identity currently in effect (falling back to `~/.dotfiles-backup/` if a
  previous run displaced it), and offers to align `profiles/personal/gitconfig` with it
- which password manager is actually installed, and which accounts are signed in
- **your existing signing key** — it reads every SSH-key item in the vault and matches
  one against the key git already signs with, so you never end up with a second key to
  register on every forge
- packages installed here that no Brewfile declares, which is what would silently go
  missing on your next Mac

Nothing is changed without asking.

## Setting up a client machine

### 1. Create the overlay item in the client's vault

One item named `dotfiles-overlay`, in **that client's vault**, with these custom fields:

| Field | Required | Contents |
|---|---|---|
| `email` | yes | Work email address |
| `name` | no | Display name for commits |
| `workdir` | no | Where the identity applies. Default `~/Dev/<slug>/` |
| `signing-key-item` | no | SSH-key item name. Default `git-signing-key` |
| `agent-keys` | no | 1Password only: a `[[ssh-keys]]` TOML fragment |
| `zsh` | no | Shell fragment: internal tooling, PATH, aliases |
| `brewfile` | no | Extra `brew` / `cask` / `tap` lines |

There is deliberately no `signingkey` field — the public key is read from the SSH-key
item at install time, so rotating a key needs no edit here.

### 2. Point the machine at it

```sh
# 1Password-backed client
./install.sh --profile work --slug acme \
             --provider onepassword --account acme.1password.com --vault Acme

# Bitwarden-backed client
./install.sh --profile work --slug acme --provider bitwarden
```

`slug` is a short local nickname. It is written to `~/.config/dotfiles/config` and to
directory names under `~/.dotfiles-local/`. It never reaches the repository.

## How identity switching works

`~/.gitconfig` is a symlink to this repo's neutral `git/gitconfig`, which includes two
generated files, both written with absolute paths so the repo can live anywhere:

- `~/.gitconfig.base.local` — written by `--link`. Points at your personal identity.
  No vault needed, so git works immediately after a clone.
- `~/.gitconfig.local` — written by `--sync-overlay`. Carries the signing key and, on a
  client machine, an `includeIf "gitdir:<workdir>"` block.

The result:

| Where you are | Identity | Signing |
|---|---|---|
| Anywhere on a personal Mac | Personal | On, with the key from your vault |
| Inside `<workdir>` on a client Mac | That client's | On, with the key from their vault |
| Anywhere else on a client Mac | That client's | On |

No manual switching, and no way to accidentally commit with the wrong address.

A client machine holds nothing personal — its own 1Password account, its own SSH key,
its own forge user — so the job identity is the default across the whole machine. A
personal default there would protect nothing and could only produce commits with the
wrong address or no signature. The `includeIf` on the work directory stays as an
explicit reinforcement, and is what would scope things correctly if one machine ever
had to serve two clients.

If the vault has not been reached yet on a client machine, git is left with **no identity
at all** (`user.useConfigOnly = true`), so commits fail loudly rather than silently going
out under your personal address.

## Signing keys

The private key lives in the vault and never touches disk — that is the whole point of
the SSH agent. "Generate if missing" therefore means *create an item in the vault*:

**An existing key is always preferred over a new one.** The installer lists the SSH-key
items it can see and reuses one rather than minting a second key you would have to
register everywhere again. Your choice is pinned in `~/.config/dotfiles/config`
(`key_item` / `key_vault`), or set it up front:

```sh
./install.sh --sync-overlay \
    --signing-key-item "Github SSH Key" --signing-key-vault Development
```

With several keys and no terminal attached it refuses to guess — picking the wrong
signing key is silent and long-lived.

Only when no key exists at all does it create one:

- **1Password** — created automatically with `op item create --category ssh`
  ([docs](https://developer.1password.com/docs/cli/ssh-keys/)). A fresh personal Mac
  provisions its own signing key with no manual step.
- **Bitwarden** — `bw` has no documented SSH-key generation, so the installer stops and
  tells you to create it in Bitwarden Desktop (*Settings → SSH agent → Add SSH key →
  Ed25519*). It deliberately does **not** improvise with a temporary `ssh-keygen` file:
  a client's private key must never touch that client's disk, not even briefly.

Either way, the installer also writes an `allowed_signers` file and wires
`gpg.ssh.allowedSignersFile` to it, so `git log --show-signature` actually verifies
instead of reporting *"No principal matched"*.

**The one step nobody can automate:** registering the public key as a *Signing Key* on
the client's GitHub/GitLab needs their credentials. The installer prints the key and
where to paste it; `--show-signing-key` reprints it any time.

## Provider differences that matter

These are not cosmetic — getting them wrong breaks commits silently:

| | 1Password | Bitwarden |
|---|---|---|
| Commit signer | `op-ssh-sign` | none — git falls back to `ssh-keygen -Y sign` |
| Agent socket | `~/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock` | `~/.bitwarden-ssh-agent.sock`, or the App Store container path |
| `agent.toml` | generated | never — it is a 1Password-only artifact |
| Key generation | automatic | manual, in the desktop app |

The socket is wired through `IdentityAgent` in `~/.ssh/config.local` rather than
`SSH_AUTH_SOCK`, because GUI apps launched from Finder or the Dock never inherit the
environment variable ([Bitwarden docs](https://bitwarden.com/help/ssh-agent/)).

## Keeping the repo neutral

The repository is public, so a slip is a public slip. Four layers, so it does not
depend on remembering:

1. `.gitignore` covers `*.local`, `.dotfiles-local/`, `.DS_Store`, `Brewfile.new`.
2. A **pre-commit hook** (installed by `--link`) rejects any staged content containing
   this machine's slug, vault, or account name.
3. `--doctor` runs a leak scan over the whole repo and flags hardcoded home paths.
4. Nothing job-specific is ever written into the repo in the first place — the installer
   only writes to `$HOME`.

## Claude Code status line

`claude/statusline.sh` renders the session line. It exists for one reason: on a
machine that serves a client, seeing **which git identity is active in this
directory** — before writing the commit — is worth more than any other status.

```
Opus 5 · api-gateway · main* · acme:dev@acme.example · ctx 63% · 5h 87% (1h) · $1.87
```

The address is resolved from inside the current directory, so `includeIf` rules are
honoured: it is the address the next commit will actually carry, not a global default.
Work identities render in a different colour from personal ones, an unsigned repo says
so, and a repo with no identity at all says that loudest — because there, commits fail.

It also reports plan usage, read from the session payload
(`.context_window.used_percentage`, `.rate_limits.five_hour`, `.rate_limits.seven_day`):

| Segment | Appears |
|---|---|
| `ctx NN%` | only past 50% — below that, how full the context is tells you nothing |
| `5h NN%` / `7d NN%` | always, when the payload carries them |
| `(1h)` after a percentage | only past 80%, when knowing the reset changes what you do next |

All three go grey → amber → red as they climb, so the line escalates on its own instead
of asking you to read numbers.

It is wired up automatically — see below.

## Claude Code settings

Claude Code loads settings user → project → local, with **no user-level local
override**, so symlinking `~/.claude/settings.json` would share every key, permission
posture included. It is generated instead, the same two-layer shape as everything else:

| File | Tracked | Holds |
|---|---|---|
| `claude/settings.base.json` | yes | model, output style, theme, deny rules, hooks, status line |
| `~/.config/dotfiles/claude-settings.json` | no | whatever this machine alone should have |

The local file wins on any key it defines, and `--link` regenerates the merge. The status
line path is rewritten to this repo's absolute location at generation time, so it works
under any username.

**`permissions.defaultMode` belongs in the local file, not the base.** Running with
`bypassPermissions` is a decision about one machine and one codebase; sharing it would
silently apply your personal posture to a client's repository.

Claude Code also writes to that file itself (`/config`, permission dialogs). Regeneration
would discard those edits, so a checksum is recorded: if the file changed since it was
last generated, `--link` names the drifted keys, keeps a copy in `~/.dotfiles-backup/`,
and tells you which of the two files to move them into.

## Tests

```sh
./tests/overlay.test.sh
```

Runs the overlay logic against a mock provider in a throwaway `$HOME` and asserts what
`git` actually resolves: identity switching in and out of the workdir, signing-key
provisioning and idempotency, the Bitwarden refusal path, the deferred guard, and purge.

Lint everything with:

```sh
shellcheck -x install.sh lib/*.sh lib/providers/*.sh hooks/pre-commit tests/*.sh
```

## Layout

```
install.sh                     entry point
lib/log.sh                     output helpers
lib/profile.sh                 machine profile (~/.config/dotfiles/config)
lib/links.sh                   declarative symlink table, backup-then-link
lib/overlay.sh                 vault -> machine-local materialization
lib/providers/{onepassword,bitwarden}.sh
Brewfile                       base packages
Brewfile.<group>               optional groups
Brewfile.provider.<provider>   the password manager app + CLI
profiles/base/                 dev keys that travel with you
profiles/personal/             personal identity, apps, shell
zsh/, git/, ssh/, starship/    the actual dotfiles
hooks/pre-commit               neutrality guard
tests/overlay.test.sh
```

Nothing is ever deleted during install: files that would be replaced are moved to
`~/.dotfiles-backup/<timestamp>/` first.

## License

MIT. See [LICENSE](LICENSE).

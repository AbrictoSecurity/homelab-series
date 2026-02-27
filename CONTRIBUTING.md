# Contributing to homelab-series

Thanks for reading the Abricto Security HomeLab Series. If you've found a bug in a script, spotted an error in the docs, or want to suggest an improvement, this guide explains how.

---

## Reporting Issues

Open a GitHub Issue and include:

- Which script or file has the problem
- The Proxmox / OS version you're running
- The exact error message or unexpected behavior
- What you expected to happen

---

## Script Standards

Every script in this repo must meet the following standards before being merged. These are non-negotiable, they exist to protect readers who copy-paste commands into production environments.

### Required Header Block

Every script must begin with this comment block:

```bash
# Script: <filename>
# Description: <one-line description of what this script does>
# Blog post: <URL of the post this script accompanies>
# Usage: bash <filename> <required-args>
# Dependencies: <list any non-standard tools, e.g., qm, flarectl, pvesh>
```

### Required Shell Options

Every script must have these on line 2 (after the shebang):

```bash
#!/bin/bash
set -euo pipefail
```

- `set -e`, exit immediately on any error
- `set -u`, treat unset variables as errors (catches typos in variable names)
- `set -o pipefail`, catch errors in piped commands, not just the last one

### Argument Validation

Every script must validate required arguments before doing anything:

```bash
DOMAIN="${1:?Usage: $0 <domain>}"
CF_TOKEN="${2:?Usage: $0 <domain> <cloudflare_token>}"
```

This ensures the script fails fast with a clear usage message rather than silently running with empty variables.

### No Hardcoded Secrets

Scripts **must not** contain hardcoded API tokens, passwords, or credentials of any kind. Acceptable patterns:

```bash
# Pass as argument (document the security implication in the header)
CF_TOKEN="${1:?Cloudflare API token required. Keep this out of shell history.}"

# Or read from a .env file (never committed)
# shellcheck source=/dev/null
source .env
```

### Backup Before Modifying System Files

Any script that modifies a system file must create a timestamped backup first:

```bash
BACKUP="/etc/network/interfaces.bak.$(date +%Y%m%d%H%M%S)"
cp /etc/network/interfaces "$BACKUP"
echo "Backup saved to $BACKUP"
```

### Success Message and Next Steps

Every script must end with a clear confirmation and a pointer to what comes next:

```bash
echo ""
echo "Done. Pi-hole is running at http://10.10.10.2/admin"
echo "Next: run 07-pihole-dns-records.sh to add local DNS entries."
```

### Permissions

Use least-privilege permissions. Never use `chmod 777`.

| Use case | Permission |
|----------|------------|
| Shell scripts | `chmod 755` |
| Config files | `chmod 644` |
| Files with credentials | `chmod 600` |

### ShellCheck

Run `shellcheck` against every script before committing:

```bash
shellcheck scripts/network/01-create-bridges.sh
```

ShellCheck also runs automatically on every push via GitHub Actions. PRs with ShellCheck failures will not be merged.

---

## Submitting a Pull Request

1. Fork the repo and create a branch: `git checkout -b fix/description-of-fix`
2. Make your changes, following the script standards above
3. Run `shellcheck` on any modified scripts
4. Commit using the convention below
5. Open a PR against `main` with a clear description of what changed and why

### Commit Message Convention

```
<type>: <short description>
```

| Type | When to use |
|------|-------------|
| `add` | New script, config, or doc file |
| `update` | Enhancement to an existing file |
| `fix` | Bug fix |
| `remove` | Deleting something |
| `docs` | README, CONTRIBUTING, or doc-only changes |
| `ci` | GitHub Actions / workflow changes |

Examples:
```
add: 04-certbot-setup.sh, wildcard cert via Let's Encrypt
fix: 03-opnsense-configure.sh, handle missing API response
docs: update README script reference table for Post 3
ci: pin shellcheck action to v1.32.0
```

---

## What Won't Be Merged

- Scripts without `set -euo pipefail`
- Hardcoded secrets, tokens, or passwords of any kind
- Scripts that fail ShellCheck without documented exceptions (`# shellcheck disable=...` with explanation)
- Changes to the network reference IPs or hostnames without a corresponding update to `docs/ip-allocation.md`
- New `.ini`, `.env`, `.pem`, `.key`, or certificate files of any kind

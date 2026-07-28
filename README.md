# PsiNix

Run a [psibase](https://github.com/gofractally/psibase) node on NixOS, deployed to a remote server with [nixos-anywhere](https://github.com/nix-community/nixos-anywhere).

Secrets (Cloudflare API token, SoftHSM PIN, Caddy admin password hash) are encrypted with [SOPS](https://github.com/getsops/sops) + [age](https://github.com/FiloSottile/age) and decrypted on the host by [sops-nix](https://github.com/Mic92/sops-nix).

You only need [Nix](https://nixos.org/download/) with flakes on your admin machine. Everything else in this guide is `nix run` / `nix shell` (no permanent `sops`/`age` install). The server never needs the `sops` CLI.

## Before you deploy (fill these in)

Edit the `let` block at the top of `configuration.nix`:

| Variable | What to put |
|----------|-------------|
| `domain` | Your domain (Cloudflare DNS) |
| `cloudFlareEmail` | Cloudflare account email (ACME) |
| `localSshKey` | Your laptop SSH **public** key (`~/.ssh/id_ed25519.pub`) |

Then create `.sops.yaml` and `secrets.yaml` as below (this repo ships placeholders only — no real secrets).

## Assumptions

- `disk-config.nix` uses the first disk as `/dev/xvda` (typical cloud/Xen). Change if your host differs (e.g. `/dev/nvme0n1` on many AWS Nitro instances).
- Initial deploy examples use `ubuntu@` as the installer SSH user. Change the user if the target image is not Ubuntu.
- A domain name + DNS by Cloudflare with an **Edit zone** token.

## Secrets overview

| Secret | Used by | How to obtain |
|--------|---------|----------------|
| `cloudflare_token` | Caddy DNS-01 TLS + ddclient | Cloudflare API token with **Edit zone DNS** |
| `softhsm_pin` | SoftHSM unlock for psibase | Random string you generate |
| `caddy_admin_hash` | HTTP basic auth on `x-*` admin hosts | bcrypt hash of a password **you choose** (via `caddy hash-password`) |

Encrypted file: `secrets.yaml` (must be git-staged/committed — see below).  
Rules + recipients: `.sops.yaml` (copy from `.sops.yaml.example`, stage/commit — public keys only).

On the host, sops-nix uses:

```nix
sops.age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
```

so the **server’s SSH host private key** is the decrypt identity. Your laptop uses the **admin age private key** in `~/.config/sops/age/keys.txt`.

## One-time: admin age key

```bash
mkdir -p ~/.config/sops/age
nix run nixpkgs#age -- keygen -o ~/.config/sops/age/keys.txt
# prints: Public key: age1...
```

That path is **user-global** (not project-local). Keep `keys.txt` private and backed up. Copy the public key into `.sops.yaml` as `admin` (below). SOPS tools pick it up automatically from there.

## One-time: project `.sops.yaml`

```bash
cp .sops.yaml.example .sops.yaml
```

Edit keys (public age keys only). **Start with admin only** — leave `host` commented until after the first NixOS boot (you need the server’s host key for `ssh-to-age`):

```yaml
# admin: your local age key (age-keygen → ~/.config/sops/age/keys.txt)
# host:  from the server after first boot:
#          ssh-keyscan -t ed25519 HOST | ssh-to-age
keys:
  - &admin age1...   # from age-keygen
  # - &host  age1...   # uncomment after ssh-to-age
creation_rules:
  - path_regex: secrets\.yaml$
    key_groups:
      - age:
          - *admin
          # - *host   # uncomment together with &host
```

Do **not** put your private age key in the repo. Stage `.sops.yaml` with the secrets file (see [Stage secrets for the flake](#stage-secrets-for-the-flake-required)).

## Fill in secrets (before or after first deploy)

You need at least the admin public key in `.sops.yaml`. Encrypt only uses the recipients in that file; your private key in `~/.config/sops/age/keys.txt` is required later to edit or rekey.

Gather values first:

| Secret | How to obtain |
|--------|----------------|
| `cloudflare_token` | Cloudflare API token with **Zone → DNS → Edit** |
| `softhsm_pin` | e.g. `nix run nixpkgs#openssl -- rand -base64 18` |
| `caddy_admin_hash` | `nix run nixpkgs#caddy -- hash-password` — when prompted, enter a new password of your own choosing; store the printed hash |

Create the file in plaintext, then encrypt in place (works even when `secrets.yaml` does not exist yet):

```bash
cat > secrets.yaml <<'EOF'
cloudflare_token: cf_xxx...
softhsm_pin: PIN_GOES_HERE
caddy_admin_hash: HASH_GOES_HERE
EOF
nix shell nixpkgs#sops -c sops encrypt --in-place secrets.yaml
```

Replace the placeholders with your real values before encrypting.

Later edits (file must already be encrypted and decryptable by your age key):

```bash
nix shell nixpkgs#sops -c sops secrets.yaml
nix shell nixpkgs#sops -c sops set secrets.yaml '["cloudflare_token"]' '"cf_xxx..."'
```

## Stage secrets for the flake (required)

Nix **flakes only see files git knows about**. If `.sops.yaml` or `secrets.yaml` are untracked, evaluate/build/deploy fails with:

```text
error: Path 'secrets.yaml' in the repository "…" is not tracked by Git.
```

After creating or changing them, **stage** (a commit is optional but recommended):

```bash
git add .sops.yaml secrets.yaml
git status   # both should be staged or already tracked — not under "Untracked files"
```

You can deploy with only a `git add` (dirty tree is fine; Nix will warn). Committing is still a good idea so the next clone has the encrypted secrets and public age recipients:

```bash
git add .sops.yaml secrets.yaml
git commit -m "Add sops recipients and encrypted secrets"
```

Do **not** commit `~/.config/sops/age/keys.txt` (private key). Encrypted `secrets.yaml` and public keys in `.sops.yaml` are safe to commit.

## Deployment

### 1. Initial install (nixos-anywhere)

```bash
nix run github:nix-community/nixos-anywhere -- \
  --generate-hardware-config nixos-generate-config ./hardware-configuration.nix \
  --flake .#generic \
  --target-host ubuntu@**IPV4**
```

After this, the machine boots NixOS with a new SSH host key. Root login uses the public key in `configuration.nix` (`localSshKey`).

**Chicken-and-egg:** until the host age recipient is in `.sops.yaml` and secrets are re-encrypted for it, sops-nix cannot decrypt on the server. Do the next step before expecting Cloudflare/Caddy/SoftHSM secrets to work, then rebuild.

### 2. Add the host age key and re-encrypt

```bash
nix shell nixpkgs#openssh nixpkgs#ssh-to-age -c sh -c \
  'ssh-keyscan -t ed25519 **IPV4** | ssh-to-age'
```

In `.sops.yaml`, **uncomment** the `host` lines and paste the printed `age1...` value:

```yaml
keys:
  - &admin age1...          # already set
  - &host  age1...          # ← from ssh-to-age
creation_rules:
  - path_regex: secrets\.yaml$
    key_groups:
      - age:
          - *admin
          - *host             # ← uncomment
```

Then rekey so the ciphertext includes the new recipient:

```bash
nix shell nixpkgs#sops -c sops updatekeys secrets.yaml
git add .sops.yaml secrets.yaml   # flake must see the updates
```

### 3. Rebuild (subsequent deploys)

```bash
# on NixOS; elsewhere: nix shell nixpkgs#nixos-rebuild -c nixos-rebuild ...
nixos-rebuild switch --flake .#generic --target-host "root@**IPV4**" --show-trace
```

## Day-2 secret changes

1. Edit with `nix shell nixpkgs#sops -c sops …` on your admin machine (same as above).
2. Stage/commit the updated `secrets.yaml`.
3. `nixos-rebuild switch ...` so the host picks up new ciphertext.

## What runs where

```text
Admin machine                          Remote NixOS host
─────────────────                      ─────────────────
sops / age CLI                         sops-nix module (no sops binary needed)
~/.config/sops/age/keys.txt (private)  /etc/ssh/ssh_host_ed25519_key (decrypt)
.sops.yaml (public recipients)         decrypts secrets.yaml at activation
encrypts secrets.yaml          → /run/secrets/… + templates for Caddy/etc.
```

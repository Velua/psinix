# PsiNix

Run a [psibase](https://github.com/gofractally/psibase) node on NixOS, deployed to a remote server with [nixos-anywhere](https://github.com/nix-community/nixos-anywhere).

Secrets (Cloudflare API token, SoftHSM PIN, Caddy admin password hash) are encrypted with [SOPS](https://github.com/getsops/sops) + [age](https://github.com/FiloSottile/age) and decrypted on the host by [sops-nix](https://github.com/Mic92/sops-nix).

This guide is a walkthrough: do the steps in order, top to bottom. Steps 1–5 happen on your admin machine before the first deploy; steps 6–8 are the deploy itself.

## Prerequisites

- [Nix](https://nixos.org/download/) with flakes on your admin machine — **NixOS is not required**; any Linux distro (or macOS, see below) with Nix installed works. Every tool below is invoked with `nix run` / `nix shell` — no permanent `sops`/`age` install needed, and the server never needs the `sops` CLI.
- Your admin machine must be able to build `x86_64-linux` derivations. Any x86_64 Linux machine can. From macOS or an ARM machine, add `--build-on-remote` to the nixos-anywhere command (Step 6) and `--build-host root@**IPV4**` to nixos-rebuild (Step 8), or configure a remote builder.
- **Windows:** Nix does not run natively, but WSL2 works. Install Nix inside WSL2 and do *everything* there: keep the repo on the WSL filesystem (not `/mnt/c/...`), generate/use the SSH key inside WSL (`~/.ssh/id_ed25519.pub` — that machine is what SSHes to the server), and the age key path in Step 2 refers to the WSL home directory. An x86 laptop under WSL2 counts as `x86_64-linux`, so no remote-build flags are needed.
- A domain with DNS hosted on Cloudflare, and the ability to create an API token with **Zone → DNS → Edit**.
- A target server you can SSH into that is running a live/installer image (the examples assume an Ubuntu image, hence `ubuntu@`; adjust the user if yours differs).
- `disk-config.nix` assumes the first disk is `/dev/xvda` (typical cloud/Xen). Change it if your host differs (e.g. `/dev/nvme0n1` on many AWS Nitro instances).

## Step 1 — Configure `configuration.nix`

Edit the `let` block at the top of `configuration.nix`:

| Variable | What to put |
|----------|-------------|
| `domain` | Your domain (Cloudflare DNS) |
| `cloudFlareEmail` | Cloudflare account email (ACME) |
| `localSshKey` | Your laptop SSH **public** key (`~/.ssh/id_ed25519.pub`) |

## Step 2 — Create your admin age key (one-time)

This key is what lets *you* encrypt and later edit the secrets file. It lives at a **user-global** path (not project-local), so you only ever do this once per machine:

```bash
mkdir -p ~/.config/sops/age
nix shell nixpkgs#age -c age-keygen -o ~/.config/sops/age/keys.txt
# prints: Public key: age1...
```

Keep `keys.txt` private and backed up — it is required for every future edit or rekey of the secrets. Never commit it. Copy the printed **public** key; you'll paste it into `.sops.yaml` in the next step. SOPS tools find the private key at this path automatically.

## Step 3 — Create the project `.sops.yaml`

`.sops.yaml` tells SOPS *who* can decrypt `secrets.yaml`. It contains **public keys only**, so it is safe to commit. There will eventually be two recipients:

- `admin` — your key from Step 2, so you can edit secrets.
- `host` — derived from the server's SSH host key, so the server can decrypt at boot. **You can't know this key yet**: the server only generates its SSH host key when NixOS first boots. So for now, start with `admin` only and leave `host` commented out — you'll return to this file in Step 7.

```bash
cp .sops.yaml.example .sops.yaml
```

Then edit it, pasting your public key from Step 2:

```yaml
# admin: your local age key (age-keygen → ~/.config/sops/age/keys.txt)
# host:  from the server after first boot:
#          ssh-keyscan -t ed25519 HOST | ssh-to-age
keys:
  - &admin age1...   # from age-keygen (Step 2)
  # - &host  age1...   # uncomment in Step 7
creation_rules:
  - path_regex: secrets\.yaml$
    key_groups:
      - age:
          - *admin
          # - *host   # uncomment in Step 7
```

## Step 4 — Create and encrypt `secrets.yaml`

Three secrets are needed. Gather the values first:

| Secret | Used by | How to obtain |
|--------|---------|----------------|
| `cloudflare_token` | Caddy DNS-01 TLS + ddclient | Cloudflare API token with **Zone → DNS → Edit** |
| `softhsm_pin` | SoftHSM unlock for psibase | Any random string, e.g. `nix run nixpkgs#openssl -- rand -base64 18` |
| `caddy_admin_hash` | HTTP basic auth on `x-*` admin hosts | `nix run nixpkgs#caddy -- hash-password` — see note below |

> **Note on `caddy_admin_hash`:** `caddy hash-password` does not generate a password for you — it prompts you to type one in. Pick (and save, e.g. in your password manager) any strong password **of your own choosing**; that password is what you'll enter at the basic-auth prompt on the `x-*` admin subdomains (username `admin`). Only the resulting bcrypt hash goes into `secrets.yaml`.

Create the file in plaintext with your real values, then encrypt it in place (encryption uses the recipients in `.sops.yaml` — currently just `admin`):

```bash
cat > secrets.yaml <<'EOF'
cloudflare_token: cf_xxx...
softhsm_pin: PIN_GOES_HERE
caddy_admin_hash: HASH_GOES_HERE
EOF
nix shell nixpkgs#sops -c sops encrypt --in-place secrets.yaml
```

To edit later (requires your private key from Step 2):

```bash
nix shell nixpkgs#sops -c sops secrets.yaml
nix shell nixpkgs#sops -c sops set secrets.yaml '["cloudflare_token"]' '"cf_xxx..."'
```

## Step 5 — Stage the files in git (required)

Nix **flakes only see files git knows about**. If `.sops.yaml` or `secrets.yaml` are untracked, evaluate/build/deploy fails with:

```text
error: Path 'secrets.yaml' in the repository "…" is not tracked by Git.
```

So after creating or changing them, stage them:

```bash
git add .sops.yaml secrets.yaml
git status   # both should be staged or already tracked — not under "Untracked files"
```

A `git add` alone is enough to deploy (a dirty tree is fine; Nix will warn). Committing is still a good idea so the next clone has the encrypted secrets and public recipients:

```bash
git commit -m "Add sops recipients and encrypted secrets"
```

Safe to commit: encrypted `secrets.yaml`, public keys in `.sops.yaml`. Never commit: `~/.config/sops/age/keys.txt` (your private key).

## Step 6 — Initial install (nixos-anywhere)

```bash
nix run github:nix-community/nixos-anywhere -- \
  --generate-hardware-config nixos-generate-config ./hardware-configuration.nix \
  --flake .#generic \
  --target-host ubuntu@**IPV4**
```

After this, the machine boots NixOS with a freshly generated SSH host key. Root login uses the public key you set in `configuration.nix` (`localSshKey`).

**Expect secrets to be broken at this point.** The server decrypts `secrets.yaml` with its SSH host key (that's the `host` recipient from Step 3), but that key didn't exist until just now — so the ciphertext isn't encrypted for it yet. Cloudflare/Caddy/SoftHSM won't work until you complete Steps 7–8.

## Step 7 — Add the host key as a recipient and re-encrypt

Get the server's host key as an age recipient:

```bash
nix shell nixpkgs#openssh nixpkgs#ssh-to-age -c sh -c \
  'ssh-keyscan -t ed25519 **IPV4** | ssh-to-age'
```

Back in `.sops.yaml` (from Step 3), **uncomment** the `host` lines and paste the printed `age1...` value:

```yaml
keys:
  - &admin age1...          # already set in Step 3
  - &host  age1...          # ← from ssh-to-age
creation_rules:
  - path_regex: secrets\.yaml$
    key_groups:
      - age:
          - *admin
          - *host             # ← uncomment
```

Then rekey the ciphertext so it includes the new recipient, and re-stage (Step 5 rule applies to every change):

```bash
nix shell nixpkgs#sops -c sops updatekeys secrets.yaml
git add .sops.yaml secrets.yaml
```

## Step 8 — Rebuild (and all subsequent deploys)

```bash
# on NixOS; elsewhere: nix shell nixpkgs#nixos-rebuild -c nixos-rebuild ...
nixos-rebuild switch --flake .#generic --target-host "root@**IPV4**" --show-trace
```

The host can now decrypt secrets at activation, and Caddy/ddclient/SoftHSM come up for real.

## Day-2: changing secrets

1. Edit with `nix shell nixpkgs#sops -c sops secrets.yaml` on your admin machine (Step 4).
2. Stage/commit the updated `secrets.yaml` (Step 5).
3. `nixos-rebuild switch ...` so the host picks up the new ciphertext (Step 8).

## Reference: how decryption works

On the host, sops-nix is configured with:

```nix
sops.age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
```

so the **server's SSH host private key** is its decrypt identity — no age key ever needs to be copied to the server. Your admin machine uses the **admin age private key** in `~/.config/sops/age/keys.txt`.

```text
Admin machine                          Remote NixOS host
─────────────────                      ─────────────────
sops / age CLI                         sops-nix module (no sops binary needed)
~/.config/sops/age/keys.txt (private)  /etc/ssh/ssh_host_ed25519_key (decrypt)
.sops.yaml (public recipients)         decrypts secrets.yaml at activation
encrypts secrets.yaml          → /run/secrets/… + templates for Caddy/etc.
```

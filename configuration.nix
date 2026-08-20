{
  modulesPath,
  config,
  lib,
  pkgs,
  unstable,
  ...
} @ args: let
  domain = "example.com"; # your domain (Cloudflare DNS)
  domainRe = lib.escapeRegex domain;
  cloudFlareEmail = "you@example.com"; # Cloudflare account email (ACME)
  localSshKey = [
    "ssh-ed25519 AAAA... comment" # your laptop's public key → root login
  ];
  producer = null; # block producer name (psinode --producer); null = non-producing node
in {
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
    (modulesPath + "/profiles/qemu-guest.nix")
    ./disk-config.nix
  ];
  boot.loader.grub = {
    # no need to set devices, disko will add all devices that have a EF02 partition to the list already
    # devices = [ ];
    efiSupport = true;
    efiInstallAsRemovable = true;
  };
  services.openssh.enable = true;

  sops = {
    defaultSopsFile = ./secrets.yaml;
    # Activation-script install runs in initrd, before ssh host keys exist.
    # A real unit is what After=sops-install-secrets.service can wait on.
    useSystemdActivation = true;
    # Age key paths for Sops on the remote host
    age.sshKeyPaths = ["/etc/ssh/ssh_host_ed25519_key"];

    # Raw API token as stored in secrets.yaml
    secrets.cloudflare_token = {};

    # Rendered into an env file for lego (security.acme DNS-01).
    templates.cloudflare-env = {
      owner = "acme";
      restartUnits = ["acme-order-renew-${domain}.service"];
      content = ''
        CLOUDFLARE_DNS_API_TOKEN=${config.sops.placeholder.cloudflare_token}
      '';
    };

    # bcrypt hash for the x-* admin login prompt (generate with: caddy hash-password)
    secrets.caddy_admin_hash = {};
    # Hex token for the parent-domain session cookie (openssl rand -hex 32).
    secrets.caddy_session_token = {};

    templates.caddy-admin-env = {
      owner = "caddy";
      restartUnits = ["caddy.service"];
      content = ''
        CADDY_ADMIN_HASH=${config.sops.placeholder.caddy_admin_hash}
        CADDY_SESSION_TOKEN=${config.sops.placeholder.caddy_session_token}
      '';
    };

    # SoftHSM user/SO PIN (softhsm2-util --init-token). Unlock after restart via x-admin.
    secrets.softhsm_pin = {
      restartUnits = ["psibase.service"];
    };
  };

  environment.systemPackages = map lib.lowPrio [
    pkgs.curl
    pkgs.gitMinimal
    pkgs.cowsay
  ];

  networking.firewall.allowedTCPPorts = [80 443];
  networking.firewall.allowedUDPPorts = [];

  # Psibase node (package + module from inputs.psibase).
  # Feature parity with psibase-node-deployment docker compose:
  #   producer, p2p, database cache, SoftHSM PKCS#11, reverse-proxy admin auth.
  # Caddy reverse_proxies **domain** / *.**domain** -> localhost:8090.
  services.psibase = {
    enable = true;
    host = domain;
    listen = 8090;
    # openFirewall not needed: only Caddy talks to psinode on loopback.

    # Match docker PRODUCER_NAME / first-run -p. Null = non-producing node (module default).
    producer = producer;
    p2p = true;
    databaseCacheSize = "2GiB";
    # Default psinode timeout is ~4s; push_boot (~9MB) over high-latency paths
    # needs longer or Caddy gets 502 mid-upload (needgenesis never clears).
    httpTimeout = 30;

    softHsm = {
      enable = true;
      pinFile = config.sops.secrets.softhsm_pin.path;
      tokenLabel = "psibase production SoftHSM";
    };

    # Caddy sets X-Auth-User on x-* after the parent-domain session (or the
    # first basic-auth prompt that issues it). Traefik admin-auth equivalent.
    environment = {
      PSIBASE_USERNAME_FIELD = "X-Auth-User";
    };
  };

  systemd.services.caddy = {
    after = ["sops-install-secrets.service"];
    wants = ["sops-install-secrets.service"];
    serviceConfig.EnvironmentFile = [
      config.sops.templates.caddy-admin-env.path
    ];
  };

  # ACME reads EnvironmentFile= at spawn. If sops has not rendered it yet,
  # the unit fails with "Failed to load environment files" and stays dead.
  # The path unit starts issuance once the Cloudflare env file appears
  # (first boot: host keys → sops → env file, after ACME already failed).
  systemd.paths."acme-order-renew-${domain}" = {
    wantedBy = ["multi-user.target"];
    pathConfig.PathExists = config.sops.templates.cloudflare-env.path;
  };
  systemd.services."acme-order-renew-${domain}" = {
    after = ["sops-install-secrets.service"];
    wants = ["sops-install-secrets.service"];
  };

  # Wildcard certs need DNS-01. Use NixOS ACME (lego) instead of
  # caddy.withPlugins so flake lock updates do not require a vendor hash.
  security.acme = {
    acceptTerms = true;
    defaults.email = cloudFlareEmail;
    certs.${domain} = {
      domain = domain;
      extraDomainNames = ["*.${domain}"];
      dnsProvider = "cloudflare";
      dnsResolver = "1.1.1.1:53";
      environmentFile = config.sops.templates.cloudflare-env.path;
      group = "caddy";
      reloadServices = ["caddy"];
    };
  };

  services.caddy = {
    enable = true;

    logFormat = ''
      level DEBUG
    '';

    # --- psibase routing (port of the Traefik routers/middlewares from
    # psibase-node-deployment) ---

    # Root domain -> psinode. Strip client-supplied X-Auth-User so it can't
    # be spoofed (Traefik's "strip-auth-header" middleware).
    virtualHosts."${domain}" = {
      useACMEHost = domain;
      extraConfig = ''
        header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload"
        reverse_proxy localhost:8090 {
          header_up -X-Auth-User
        }
      '';
    };

    # Wildcard: x-* admin surfaces share one parent-domain session cookie
    # (set after a single basic-auth prompt). The Peers panel fetches
    # x-peers with credentials: include; a per-host Authorization header
    # would not be sent. psinode still authorizes via X-Auth-User.
    # Not gated here (psinode checks these itself):
    #   GET x-peers/p2p — node-to-node handshake (checkP2PAuth / --p2p)
    #   OPTIONS on x-*  — CORS preflight (no credentials)
    virtualHosts."*.${domain}" = {
      useACMEHost = domain;
      extraConfig = ''
        header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload"

        @xapps header_regexp xhost Host ^x-[^.]+[.]${domainRe}$
        @xpeersP2p {
          host x-peers.${domain}
          path /p2p
          method GET
        }
        @xpreflight {
          header_regexp xhost Host ^x-[^.]+[.]${domainRe}$
          method OPTIONS
        }
        @xsession {
          header_regexp xhost Host ^x-[^.]+[.]${domainRe}$
          header_regexp Cookie `(?:^|;\s*)psinix_session={$CADDY_SESSION_TOKEN}(?:;|$)`
        }

        handle @xpeersP2p {
          reverse_proxy localhost:8090 {
            header_up -X-Auth-User
          }
        }

        handle @xpreflight {
          reverse_proxy localhost:8090 {
            header_up -X-Auth-User
          }
        }

        handle @xsession {
          reverse_proxy localhost:8090 {
            header_up X-Auth-User admin
          }
        }

        handle @xapps {
          basic_auth {
            admin {$CADDY_ADMIN_HASH}
          }
          reverse_proxy localhost:8090 {
            header_up X-Auth-User {http.auth.user.id}
            header_down +Set-Cookie "psinix_session={$CADDY_SESSION_TOKEN}; Domain=.${domain}; Path=/; Secure; HttpOnly; SameSite=Lax; Max-Age=2592000"
          }
        }

        # x-admin dashboard fetches GET transact.{host}/stats from the browser.
        # That call is cross-subdomain: no X-Auth-User, no admin JWT, and the
        # real client IP in X-Forwarded-For fails psinode's isAdmin() check → 401.
        # (Caddy basic auth on x-admin cannot attach to this request.)
        # Treat only this metrics endpoint as loopback so isAdminSocket passes.
        # Does not open other admin APIs (/jwt_key, /native/admin/*, etc.).
        @transactStats {
          host transact.${domain}
          path /stats
        }
        handle @transactStats {
          reverse_proxy localhost:8090 {
            header_up -X-Auth-User
            header_up X-Forwarded-For 127.0.0.1
            header_up -Forwarded
          }
        }

        handle {
          reverse_proxy localhost:8090 {
            header_up -X-Auth-User
          }
        }
      '';
    };
  };

  services.ddclient = {
    enable = true;
    interval = "5min";
    protocol = "cloudflare";
    username = "token";
    passwordFile = config.sops.secrets.cloudflare_token.path;
    domains = ["*.${domain}" "${domain}"];
    zone = domain;
    ssl = true;
    verbose = true;
  };

  users.users.root.openssh.authorizedKeys.keys =
    localSshKey
    ++ (args.extraPublicKeys or []); # this is used for unit-testing this module and can be removed if not needed

  system.stateVersion = "24.05";
  nix.settings.experimental-features = ["nix-command" "flakes"];
}

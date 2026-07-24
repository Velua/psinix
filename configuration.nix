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
  localSshKey = "ssh-ed25519 AAAA... comment"; # your laptop's public key → root login
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
    # Age key paths for Sops on the remote host
    age.sshKeyPaths = ["/etc/ssh/ssh_host_ed25519_key"];

    # Raw API token as stored in secrets.yaml
    secrets.cloudflare_token = {};

    # Rendered into an env file for Caddy
    templates.cloudflare-env = {
      owner = "caddy";
      restartUnits = ["caddy.service"];
      content = ''
        CLOUDFLARE_API_TOKEN=${config.sops.placeholder.cloudflare_token}
      '';
    };

    # bcrypt hash for the x-* admin subdomains (generate with: caddy hash-password)
    secrets.caddy_admin_hash = {};

    templates.caddy-admin-env = {
      owner = "caddy";
      restartUnits = ["caddy.service"];
      content = ''
        CADDY_ADMIN_HASH=${config.sops.placeholder.caddy_admin_hash}
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

    # Match docker PRODUCER_NAME / first-run -p. Change if your chain uses another name.
    producer = "a";
    p2p = true;
    databaseCacheSize = "2GiB";

    softHsm = {
      enable = true;
      pinFile = config.sops.secrets.softhsm_pin.path;
      tokenLabel = "psibase production SoftHSM";
    };

    # Caddy sets X-Auth-User on x-* after basic auth (Traefik admin-auth equivalent).
    environment = {
      PSIBASE_USERNAME_FIELD = "X-Auth-User";
    };
  };

  systemd.services.caddy.serviceConfig.EnvironmentFile = [
    config.sops.templates.cloudflare-env.path
    config.sops.templates.caddy-admin-env.path
  ];

  services.caddy = {
    enable = true;

    email = cloudFlareEmail;
    acmeCA = null;
    logFormat = ''
      level DEBUG
    '';

    package = pkgs.caddy.withPlugins {
      plugins = ["github.com/caddy-dns/cloudflare@v0.2.4"];
      hash = "sha256-hEHgAG0F0ozHRAPuxEqLyTATBrE+pajeXDiSNwniorg=";
    };

    # --- psibase routing (port of the Traefik routers/middlewares from
    # psibase-node-deployment) ---

    # Root domain -> psinode. Strip client-supplied X-Auth-User so it can't
    # be spoofed (Traefik's "strip-auth-header" middleware).
    virtualHosts."${domain}" = {
      extraConfig = ''
        tls {
          dns cloudflare {env.CLOUDFLARE_API_TOKEN}
        }
        header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload"
        reverse_proxy localhost:8090 {
          header_up -X-Auth-User
        }
      '';
    };

    # Wildcard: x-* admin apps get basic auth, with the authenticated
    # username injected as X-Auth-User (Traefik's "admin-auth" headerField;
    # psinode reads it via PSIBASE_USERNAME_FIELD). Everything else goes
    # straight to psinode, header stripped.
    virtualHosts."*.${domain}" = {
      extraConfig = ''
        tls {
          dns cloudflare {env.CLOUDFLARE_API_TOKEN}
        }
        header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload"

        @xapps header_regexp xhost Host ^x-[^.]+[.]${domainRe}$
        handle @xapps {
          # Require HTTP basic auth (hash from sops → CADDY_ADMIN_HASH).
          # Pass the authenticated username to psinode as X-Auth-User.
          basic_auth {
            admin {$CADDY_ADMIN_HASH}
          }
          reverse_proxy localhost:8090 {
            header_up X-Auth-User {http.auth.user.id}
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
    [
      localSshKey
    ]
    ++ (args.extraPublicKeys or []); # this is used for unit-testing this module and can be removed if not needed

  system.stateVersion = "24.05";
  nix.settings.experimental-features = ["nix-command" "flakes"];
}

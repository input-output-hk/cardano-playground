parts @ {
  self,
  inputs,
  moduleWithSystem,
  ...
}: {
  flake.nixosModules.common = moduleWithSystem ({
    inputs',
    self',
  }: {
    name,
    options,
    config,
    pkgs,
    lib,
    nodes,
    ...
  }: {
    imports = [
      inputs.sops-nix.nixosModules.default
      inputs.auth-keys-hub.nixosModules.auth-keys-hub
    ];

    deployment.targetHost = name;

    networking = {
      hostName = name;
      firewall = {
        enable = true;
        allowedTCPPorts = [22];
        allowedUDPPorts = [];
      };
    };

    time.timeZone = "UTC";
    programs.sysdig.enable = true;
    i18n.supportedLocales = ["en_US.UTF-8/UTF-8" "en_US/ISO-8859-1"];

    boot = {
      tmp.cleanOnBoot = true;
      kernelParams = ["boot.trace"];
      loader.grub.configurationLimit = 10;
    };

    # On boot, SOPS runs in stage 2 without networking, this prevents KMS from
    # working, so we repeat the activation script until decryption succeeds.
    systemd.services.sops-boot-fix = {
      wantedBy = ["multi-user.target"];
      after = ["network-online.target"];

      script = ''
        ${config.system.activationScripts.setupSecrets.text}

        # For wireguard enabled machines
        systemctl list-unit-files wireguard-wg0.service &> /dev/null \
          && systemctl restart wireguard-wg0.service
      '';

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        Restart = "on-failure"; # because oneshot
        RestartSec = "2s";
      };
    };

    documentation = {
      nixos.enable = false;
      man.man-db.enable = false;
      info.enable = false;
      doc.enable = false;
    };

    environment.systemPackages = with pkgs; [
      bat
      bind
      di
      dnsutils
      fd
      file
      htop
      jq
      lsof
      ncdu
      ripgrep
      tree
      nano
      tcpdump
      tmux
      glances
      gitMinimal
      sops
      awscli2
      pciutils
    ];

    sops.defaultSopsFormat = "binary";

    sops.secrets.github-token = {
      sopsFile = "${self}/secrets/github-token.enc";
      owner = config.programs.auth-keys-hub.user;
      inherit (config.programs.auth-keys-hub) group;
    };

    programs.auth-keys-hub = {
      enable = true;
      package = inputs'.auth-keys-hub.packages.auth-keys-hub;
      github = {
        teams = [
          "input-output-hk/node-sre"
        ];
        tokenFile = config.sops.secrets.github-token.path;
      };
    };

    services = {
      chrony.enable = true;
      fail2ban.enable = true;
      openssh = {
        enable = true;
        settings.PasswordAuthentication = false;
      };
    };

    nix = {
      registry.nixpkgs.flake = inputs.nixpkgs;
      optimise.automatic = true;
      gc.automatic = true;

      settings = {
        max-jobs = "auto";
        experimental-features = ["nix-command" "flakes" "cgroups"];
        auto-optimise-store = true;
        system-features = ["recursive-nix" "nixos-test"];
        builders-use-substitutes = true;
        show-trace = true;
        keep-outputs = true;
        keep-derivations = true;
        tarball-ttl = 60 * 60 * 72;
      };
    };

    security.tpm2 = {
      enable = true;
      pkcs11.enable = true;
    };

    hardware = {
      cpu.amd.updateMicrocode = true;
      enableRedistributableFirmware = true;
    };
  });
}

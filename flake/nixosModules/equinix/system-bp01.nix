{
  self,
  inputs,
  moduleWithSystem,
  ...
}: {
  flake.nixosModules.system-bp01 = moduleWithSystem ({system}: {config, ...}: {
    imports = [
      {
        boot.kernelModules = ["dm_multipath" "dm_round_robin" "ipmi_watchdog"];
        services.openssh.enable = true;
      }
      {
        boot.initrd.availableKernelModules = [
          "xhci_pci"
          "ahci"
          "usbhid"
          "sd_mod"
        ];

        boot.kernelModules = ["kvm-intel"];
        boot.kernelParams = ["console=ttyS1,115200n8"];
        boot.extraModulePackages = [];
      }
      (
        {lib, ...}: {
          boot.loader.grub.extraConfig = ''
            serial --unit=0 --speed=115200 --word=8 --parity=no --stop=1
            terminal_output serial console
            terminal_input serial console
          '';
          nix.settings.max-jobs = lib.mkDefault 16;
        }
      )
      {
        swapDevices = [
          {
            device = "/dev/disk/by-id/ata-INTEL_SSDSC2KB480G8_BTYF01750FL8480BGN-part2";
          }
        ];

        fileSystems = {
          "/" = {
            device = "/dev/disk/by-id/ata-INTEL_SSDSC2KB480G8_BTYF01750FL8480BGN-part3";
            fsType = "ext4";
          };
        };

        boot.loader.grub.devices = ["/dev/disk/by-id/ata-INTEL_SSDSC2KB480G8_BTYF01750FL8480BGN"];
      }
      {networking.hostId = "994c8959";}
      (
        {modulesPath, ...}: {
          networking.hostName = "bp01";
          networking.useNetworkd = true;

          systemd.network.networks."40-bond0" = {
            matchConfig.Name = "bond0";
            linkConfig = {
              RequiredForOnline = "carrier";
              MACAddress = "b4:96:91:70:18:b8";
            };
            networkConfig.LinkLocalAddressing = "no";
            dns = [
              "147.75.207.207"
              "147.75.207.208"
            ];
          };

          boot.extraModprobeConfig = "options bonding max_bonds=0";
          systemd.network.netdevs = {
            "10-bond0" = {
              netdevConfig = {
                Kind = "bond";
                Name = "bond0";
              };
              bondConfig = {
                Mode = "802.3ad";
                LACPTransmitRate = "fast";
                TransmitHashPolicy = "layer3+4";
                DownDelaySec = 0.2;
                UpDelaySec = 0.2;
                MIIMonitorSec = 0.1;
              };
            };
          };

          systemd.network.networks."30-eno1" = {
            matchConfig = {
              Name = "eno1";
              PermanentMACAddress = "b4:96:91:70:18:b8";
            };
            networkConfig.Bond = "bond0";
          };

          systemd.network.networks."30-eno2" = {
            matchConfig = {
              Name = "eno2";
              PermanentMACAddress = "b4:96:91:70:18:b9";
            };
            networkConfig.Bond = "bond0";
          };

          systemd.network.networks."40-bond0".addresses = [
            {
              addressConfig.Address = "147.28.148.163/31";
            }
            {
              addressConfig.Address = "2604:1380:4111:d300::1/127";
            }
            {
              addressConfig.Address = "10.65.51.1/31";
            }
          ];
          systemd.network.networks."40-bond0".routes = [
            {
              routeConfig.Gateway = "147.28.148.162";
            }
            {
              routeConfig.Gateway = "2604:1380:4111:d300::";
            }
            {
              routeConfig.Gateway = "10.65.51.0";
            }
          ];
        }
      )
    ];
  });
}

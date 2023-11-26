{ config, modulesPath, lib, pkgs, ... }:
let
  efiArch = pkgs.stdenv.hostPlatform.efiArch;
in
{

  imports = [
    (modulesPath + "/image/repart.nix")
  ];

  system.build.imageInfo = pkgs.writers.writeJSON "image-info.json" {
    label = config.system.nixos.label;
    system = pkgs.stdenv.hostPlatform.system;
    format = "raw";
    file = "${config.system.build.image}/image.raw";
    boot_mode = "uefi";
  };

  image.repart.name = "${config.system.nixos.distroId}-${config.system.nixos.label}-${pkgs.stdenv.hostPlatform.system}";
  image.repart.partitions = {
    "00-esp" = {
      contents = {
        "/EFI/systemd/systemd-boot${efiArch}.efi".source =
          "${pkgs.systemd}/lib/systemd/boot/efi/systemd-boot${efiArch}.efi";
        "/EFI/BOOT/BOOT${lib.toUpper efiArch}.EFI".source =
          "${pkgs.systemd}/lib/systemd/boot/efi/systemd-boot${efiArch}.efi";

        # TODO: nixos-generation-1.conf
        "/loader/entries/nixos.conf".source = pkgs.writeText "nixos.conf" ''
          title NixOS
          linux /EFI/nixos/kernel.efi
          initrd /EFI/nixos/initrd.efi
          options init=${config.system.build.toplevel}/init ${toString config.boot.kernelParams}
        '';

        "/EFI/nixos/kernel.efi".source =
          "${config.boot.kernelPackages.kernel}/${config.system.boot.loader.kernelFile}";

        "/EFI/nixos/initrd.efi".source =
          "${config.system.build.initialRamdisk}/${config.system.boot.loader.initrdFile}";
      };
      repartConfig = {
        Type = "esp";
        Format = "vfat";
        SizeMinBytes = "1G";
      };
    };
    "01-root" = {
      storePaths = [ config.system.build.toplevel ];
      repartConfig = {
        Type = "root";
        Label = "nixos";
        Format = "ext4";
        Minimize = "guess";
      };
    };
  };

  systemd.repart.enable = true;
  systemd.repart.partitions = {
    "01-root" = { Type = "root"; };
  };

  fileSystems = {
    "/boot" = {
      device = "/dev/disk/by-partlabel/ESP";
      fsType = "vfat";
    };
    "/" = {
      device = "/dev/disk/by-partlabel/nixos";
      fsType = "ext4";
      autoResize = true;
    };
  };

  boot.loader = {
    timeout = 1;
    systemd-boot.enable = true;
  };

  security.sudo.wheelNeedsPassword = false;
  users.users.ec2-user = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
  };

  services.openssh.enable = true;

  systemd.services.print-ssh-host-keys = {
    description = "Print SSH host keys to console";
    after = [ "sshd.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      StandardOutput = "journal+console";
    };
    script = ''
      echo -----BEGIN SSH HOST KEY KEYS-----
      cat /etc/ssh/ssh_host_*_key.pub
      echo -----END SSH HOST KEY KEYS-----

      echo -----BEGIN SSH HOST KEY FINGERPRINTS-----
      for f in /etc/ssh/ssh_host_*_key.pub; do
        ${pkgs.openssh}/bin/ssh-keygen -l -f $f
      done
      echo -----END SSH HOST KEY FINGERPRINTS-----
    '';
  };

  systemd.services.ec2-metadata = {
    description = "Fetch EC2 metadata and set up ssh keys for ec2-user";
    after = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = { Type = "oneshot"; };

    script = ''
      token=$(${pkgs.curl}/bin/curl --silent --show-error --fail-with-body --retry 20 --retry-connrefused  -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 60") || exit 1
      function imds {
        ${pkgs.curl}/bin/curl --silent --show-error --fail-with-body --retry 20 --retry-connrefused --header "X-aws-ec2-metadata-token: $token"  "http://169.254.169.254/latest/$1"
      }
      if [ -e /home/ec2-user/.ssh/authorized_keys ]; then
        exit 0
      fi

      mkdir -p /home/ec2-user/.ssh
      chmod 700 /home/ec2-user/.ssh
      chown -R ec2-user:users /home/ec2-user/.ssh

      for i in $(imds meta-data/public-keys/); do
        imds "meta-data/public-keys/''${i}openssh-key" >> /home/ec2-user/.ssh/authorized_keys
      done

      chmod 600 /home/ec2-user/.ssh/authorized_keys
    '';
  };

  # Fetch from DHCP
  networking.hostName = lib.mkDefault "";



}

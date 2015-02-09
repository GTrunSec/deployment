{ pkgs, lib, config, nodes, resources, ... }:

with lib;

let
  hydraSrc = pkgs.fetchFromGitHub {
    repo = "hydra";
    owner = "NixOS";
    rev = "ea815d55b8d1a76adbabd858b16aaa45221179d0";
    sha256 = "0n7z6yqlcra0hyp1b60nrwz0zk4jwrrx77afz818iw5p7snj69px";
  };

  hydraRelease = import "${hydraSrc}/release.nix" {
    inherit hydraSrc;
    officialRelease = true;
  };

  hydraModule = import "${hydraSrc}/hydra-module.nix";

  hydra = builtins.getAttr config.nixpkgs.system hydraRelease.build;

  buildUser = "hydrabuild";

  isBuildNode = name: node: hasAttr buildUser node.config.users.extraUsers;
  buildNodes = filterAttrs isBuildNode nodes;

  buildKey = resources.sshKeyPairs."hydra-build".privateKey;
in {
  imports = singleton hydraModule;

  services.hydra = {
    package = hydra;
    enable = true;
    hydraURL = "https://headcounter.org/hydra/";
    notificationSender = "hydra@headcounter.org";
    dbi = "dbi:Pg:dbname=hydra;";
    listenHost = "localhost";
  };

  users.extraUsers.hydra.uid = 2000;

  nix.maxJobs = mkForce 0;
  nix.distributedBuilds = true;
  nix.buildMachines = flip mapAttrsToList buildNodes (hostName: node: {
    inherit hostName;
    inherit (node.config.nix) maxJobs;
    systems = if node.config.nixpkgs.system == "x86_64-linux"
              then [ "i686-linux" "x86_64-linux" ]
              else singleton node.config.nixpkgs.system;
    sshKey = "/run/keys/buildkey.priv";
    sshUser = buildUser;
    supportedFeatures = [ "kvm" "nixos-test" ];
  });

  deployment.keys."signkey.priv".text = readFile ./ssl/signing-key.sec;
  deployment.keys."buildkey.priv".text = buildKey;
  deployment.storeKeysOnMachine = false;

  environment.etc."nix/signing-key.sec".source = "/run/keys/signkey.priv";

  services.postgresql.enable = true;
  services.postgresql.package = pkgs.postgresql93;
  services.postgresql.authentication = ''
    local hydra hydra peer
  '';

  nix.gc.automatic = true; # No --max-freed, because df is unreliable on btrfs.
}

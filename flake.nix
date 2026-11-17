{
  description = "farbenbuilds/tachyon - an RFC 6455 WebSocket implementation in Zig";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    zig-overlay.url = "github:mitchellh/zig-overlay";
    zig-overlay.inputs.nixpkgs.follows = "nixpkgs";
    zon2nix.url = "github:jcollie/zon2nix";

    # Pinned framing engine. Keeping the release source as a flake input lets
    # the build seed Zig's cache without network access in the Nix sandbox.
    zslay = {
      url = "https://github.com/farbenbuilds/zslay/archive/refs/tags/v0.4.0.tar.gz";
      flake = false;
    };
  };

  outputs = inputs @ {flake-parts, ...}:
    flake-parts.lib.mkFlake {inherit inputs;} {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
        "x86_64-darwin"
      ];

      perSystem = {
        pkgs,
        system,
        ...
      }: let
        isLinux = pkgs.stdenv.hostPlatform.isLinux;
        pkgsMusl =
          if isLinux
          then pkgs.pkgsMusl
          else null;

        zig = inputs.zig-overlay.packages.${system}."0.17.1";
        # zon2nix does not publish packages for every supported Darwin system.
        zon2nixPackage = (inputs.zon2nix.packages.${system} or {}).zon2nix or null;

        mkDevShell = packagePkgs:
          packagePkgs.mkShell {
            packages =
              [
                zig
                pkgs.zls
                pkgs.pre-commit
                pkgs.ripgrep
              ]
              ++ pkgs.lib.optional
              (zon2nixPackage != null && packagePkgs.stdenv.hostPlatform.isGnu)
              zon2nixPackage;
          };
      in {
        formatter = pkgs.alejandra;

        checks.format =
          pkgs.runCommand "tachyon-nix-format" {
            nativeBuildInputs = [pkgs.alejandra];
          } ''
            alejandra --check ${./flake.nix}
            touch $out
          '';

        devShells =
          {
            default = mkDevShell pkgs;
          }
          // pkgs.lib.optionalAttrs isLinux {
            musl = mkDevShell pkgsMusl;
          };
      };
    };
}

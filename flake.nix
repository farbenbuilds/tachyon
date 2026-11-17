{
  description = "farbenbuilds/tachyon - an RFC 6455 WebSocket implementation in Zig";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    zig-overlay.url = "github:mitchellh/zig-overlay";
    zig-overlay.inputs.nixpkgs.follows = "nixpkgs";
    zon2nix.url = "github:jcollie/zon2nix";
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
        zigPackages = pkgs.callPackage ./build.zig.zon.nix {};

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

        mkTestCheck = name: packagePkgs:
          packagePkgs.stdenv.mkDerivation {
            inherit name;
            src = ./.;
            nativeBuildInputs = [zig];
            buildPhase = ''
              export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache
              zig build test --system ${zigPackages} --summary all
            '';
            installPhase = "touch $out";
          };
      in {
        formatter = pkgs.alejandra;

        checks =
          {
            format =
              pkgs.runCommand "tachyon-nix-format" {
                nativeBuildInputs = [pkgs.alejandra];
              } ''
                alejandra --check ${./flake.nix}
                touch $out
              '';

            test-default = mkTestCheck "tachyon-test-default" pkgs;
          }
          // pkgs.lib.optionalAttrs isLinux {
            test-musl = mkTestCheck "tachyon-test-musl" pkgsMusl;
          };

        packages.default = pkgs.stdenv.mkDerivation {
          pname = "tachyon";
          version = "0.0.0";
          src = ./.;
          nativeBuildInputs = [zig];
          buildPhase = ''
            export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache
            zig build -Doptimize=ReleaseSafe --system ${zigPackages}
          '';
          installPhase = ''
            mkdir -p $out
            cp -r zig-out/lib $out/lib
            test -n "$(ls -A $out/lib)"
          '';
        };

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

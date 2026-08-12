{
  description = "Personal Coder workspace extras — layered on top of coder-nix-devenv";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";

    # The shared team toolchain. This repo deliberately does NOT copy anything
    # from it — it composes on top, so personal tools never end up in the
    # template everyone else installs.
    devenv = {
      url = "github:haroun-mj-ai/coder-nix-devenv";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, flake-utils, devenv }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          config.allowUnfree = true;
        };

        # roborev has no nixpkgs attribute, so it is packaged here from the
        # upstream release tarballs. See pkgs/roborev.nix.
        roborev = pkgs.callPackage ./pkgs/roborev.nix { };

        # THE source of truth for the extras. Add a package here and nowhere
        # else, then run ./scripts/export-packages.sh to refresh the README.
        extraAttrs = {
          # Background AI code review. Pinned to claude-code + sonnet by
          # ~/.roborev/config.toml, which `scripts/install.sh` does not touch.
          inherit roborev;

          # fish-style inline autosuggestions for bash, drawn from history.
          # Wired up (with TAB bound to accept) by scripts/install.sh.
          inherit (pkgs) blesh;

          # git subcommand/flag completion. Absent from the base workspace
          # image, so bare bash has no `git ` completion without it.
          inherit (pkgs) bash-completion;

          # Autopilot scheduler substrate: a persistent session to hold
          # supercronic, and the cron-alike itself. Wired up by
          # scripts/install-autopilot.sh.
          inherit (pkgs) tmux;
          inherit (pkgs) supercronic;

          # JSON workhorse for the autopilot scripts and any gh pipelines the
          # headless skills compose; the scripts fall back to python3 without
          # it, but jq is the primary branch.
          inherit (pkgs) jq;
        };

        extras = builtins.attrValues extraAttrs;
        base = devenv.packages.${system}.default;
      in
      {
        packages = {
          inherit roborev;

          # Just the extras. This is the default because the whole point of the
          # repo is the layer, not a second copy of the team toolchain:
          #   nix profile add github:haroun-mj-ai/coder-packages
          default = pkgs.buildEnv {
            name = "coder-packages-extras";
            paths = extras;
          };

          # Team toolchain + extras, for a workspace starting from nothing.
          full = pkgs.buildEnv {
            name = "coder-packages-full";
            paths = [ base ] ++ extras;
          };
        };

        devShells = {
          default = pkgs.mkShell { packages = extras; };
          full = pkgs.mkShell { packages = [ base ] ++ extras; };
        };

        # Machine-readable inventory for scripts/export-packages.sh, mirroring
        # the base repo's toolchainInfo so the README table cannot drift.
        extrasInfo = nixpkgs.lib.mapAttrsToList
          (attr: p: {
            name = attr;
            version = p.version or "";
            unfree = !(p.meta.license.free or true);
          })
          extraAttrs;
      });
}

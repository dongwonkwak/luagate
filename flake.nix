{
  description = "LuaGate — OpenResty API Gateway development environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
      in
      {
        devShells.default = pkgs.mkShell {
          name = "luagate";

          packages = with pkgs; [
            # ── OpenResty + Lua ──────────────────────────────────────────
            openresty
            luajit
            luarocks

            # ── Lua tooling (LuaJIT / Lua 5.1 semantics — matches OpenResty) ──
            luajitPackages.busted
            luajitPackages.luacheck
            stylua

            # ── Rust tooling ──────────────────────────────────────────────
            rustc
            cargo
            clippy
            rustfmt
            clang-tools   # clang-format (설정 파일 포맷용으로 유지)

            # ── Perl tooling ─────────────────────────────────────────────
            perl
            perlPackages.Appcpanminus

            # ── Benchmarking ─────────────────────────────────────────────
            wrk
            vegeta

            # ── Frontend ─────────────────────────────────────────────────
            nodejs_22
            nodePackages.npm
            nodePackages.markdownlint-cli

            # ── Git hooks ─────────────────────────────────────────────────
            pre-commit
            shellcheck
            python3Packages.detect-secrets

            # ── Docs ─────────────────────────────────────────────────────
            luajitPackages.ldoc

            # ── VHS (terminal GIF recorder) ──────────────────────────────
            vhs

            # ── Misc ──────────────────────────────────────────────────────
            gnumake
            git
            curl
            jq
          ];

          shellHook = ''
            echo ""
            echo "  LuaGate dev shell ready"
            echo "  OpenResty: $(openresty -v 2>&1 | head -1)"
            echo "  LuaJIT:    $(luajit -v 2>&1 | head -1)"
            echo "  Node.js:   $(node --version)"
            echo ""
          '';
        };
      }
    );
}

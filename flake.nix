{
  inputs = {
    flake-utils.url = "github:numtide/flake-utils";
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
  };

  outputs =
    {
      flake-utils,
      nixpkgs,
      ...
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = (import nixpkgs) {
          inherit system;
        };
      in
      {
        devShell = pkgs.mkShell {
          buildInputs = with pkgs; [
            zig
            zls
          ];

          nativeBuildInputs = with pkgs; [
            glfw
          ];

          shellHook = ''
            # Issue: https://github.com/ziglang/zig/issues/18998
            unset NIX_CFLAGS_COMPILE
            alias zed='zeditor'
          '';
        };
      }
    );
}

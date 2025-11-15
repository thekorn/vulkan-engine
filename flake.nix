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
          buildInputs =
            with pkgs;
            [
              zig
              zls
              shaderc
              pkg-config
              vulkan-headers
              vulkan-loader.dev
              vulkan-loader
              vulkan-validation-layers

              # for [rift engine]
              #glslang.bin
              #freetype.out
              #freetype.dev
            ]
            ++ (pkgs.lib.optionals pkgs.stdenv.isLinux [ libGL.dev ]);

          nativeBuildInputs =
            with pkgs;
            [
              glfw
            ]
            ++ (pkgs.lib.optionals pkgs.stdenv.isLinux [ libGL ]);

          shellHook = ''
            # Issue: https://github.com/ziglang/zig/issues/18998
            # workaround warnings like `warning: Unrecognized C flag from NIX_CFLAGS_COMPILE: -fmacro-prefix-map=`
            unset NIX_CFLAGS_COMPILE
            alias zed='zeditor'
          '';

          VK_LAYER_PATH = "${pkgs.vulkan-validation-layers}/share/vulkan/explicit_layer.d";
        };
      }
    );
}

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
        vulkan-engine = pkgs.stdenv.mkDerivation (finalAttrs: {
          pname = "vulkan-engine";
          version = "0.0.0";

          src = pkgs.lib.cleanSource ./.;

          zigDeps = pkgs.zig_0_16.fetchDeps {
            inherit (finalAttrs) pname version src;
            hash = "sha256-65a9CLKMNWtrUVgzOK2BS+QT8S7cCRY4IZy8c/csbE0=";
          };

          nativeBuildInputs = with pkgs; [
            zig_0_16.hook
            pkg-config
            shaderc
          ];

          buildInputs =
            with pkgs;
            [
              glfw
              vulkan-headers
              vulkan-loader.dev
              vulkan-loader
              tinyobjloader
            ]
            ++ (pkgs.lib.optionals pkgs.stdenv.isLinux [ libGL ]);

          postConfigure = ''
            ln -s ${finalAttrs.zigDeps} "$ZIG_GLOBAL_CACHE_DIR/p"
          '';

          meta = {
            description = "Small Vulkan rendering engine written in Zig";
            homepage = "https://github.com/thekorn/vulkan-engine";
            license = pkgs.lib.licenses.mit;
            mainProgram = "vulkan_engine";
          };
        });
      in
      {
        packages = {
          default = vulkan-engine;
          vulkan-engine = vulkan-engine;
        };

        apps.default = {
          type = "app";
          program = "${vulkan-engine}/bin/vulkan_engine";
        };

        devShell = pkgs.mkShell {
          buildInputs =
            with pkgs;
            [
              zig_0_16
              zls_0_16
              zig-zlint
              codebook
              cloc
              shaderc
              jq
              pkg-config
              vulkan-headers
              vulkan-loader.dev
              vulkan-loader
              vulkan-validation-layers
              tinyobjloader

              # for [rift engine]
              #glslang.bin
              #freetype.out
              #freetype.dev
            ]
            ++ (pkgs.lib.optionals pkgs.stdenv.isLinux [
              libGL.dev
              kcov # only packaged for Linux in nixpkgs
            ]);

          nativeBuildInputs =
            with pkgs;
            [
              glfw
            ]
            ++ (pkgs.lib.optionals pkgs.stdenv.isLinux [ libGL ]);

          shellHook = ''
            alias zed='zeditor'
          '';

          VK_LAYER_PATH = "${pkgs.vulkan-validation-layers}/share/vulkan/explicit_layer.d";
        };
      }
    );
}

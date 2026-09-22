{
  inputs = {
    flake-utils.url = "github:numtide/flake-utils";
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    zig-overlay.url = "github:mitchellh/zig-overlay";
    zig-overlay.inputs.nixpkgs.follows = "nixpkgs";
    zcov-src.url = "github:ericsssan/zcov/d5b606ab43b31fbf4ba88b6484be95cb03747de2";
    zcov-src.flake = false;
  };

  outputs =
    {
      flake-utils,
      nixpkgs,
      zcov-src,
      zig-overlay,
      ...
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = (import nixpkgs) {
          inherit system;
        };
        toolchain = import ./nix/toolchain.nix {
          inherit pkgs zig-overlay zcov-src;
        };
        inherit (toolchain) zig zig-target-flags;
        vulkan-engine = pkgs.stdenv.mkDerivation (finalAttrs: {
          pname = "vulkan-engine";
          version = "0.0.0";

          src = pkgs.lib.cleanSource ./.;

          zigDeps = zig.fetchDeps {
            inherit (finalAttrs) pname version src;
            hash = "sha256-P1y4Nk+KczNmafK+bh31DB9ekk6qkx4mpG77wk7M72s=";
          };

          nativeBuildInputs = [
            zig
            pkgs.pkg-config
            pkgs.shaderc
          ] ++ pkgs.lib.optionals pkgs.stdenv.isLinux [ pkgs.autoPatchelfHook ];

          buildInputs =
            with pkgs;
            [
              glfw
              vulkan-headers
              vulkan-loader.dev
              vulkan-loader
              tinyobjloader
            ]
            ++ (pkgs.lib.optionals pkgs.stdenv.isLinux [
              libGL
              stdenv.cc.libc
            ]);

          # Zig supplies the Nix dynamic linker directly, so preserve its
          # matching libc in the runtime search path when autoPatchelf fixes
          # the executable.
          autoPatchelfFlags = pkgs.lib.optionals pkgs.stdenv.isLinux [ "--keep-libc" ];

          configurePhase = ''
            runHook preConfigure
            export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-cache"
            mkdir -p "$ZIG_GLOBAL_CACHE_DIR"
            runHook postConfigure
          '';

          postConfigure = ''
            ln -s ${finalAttrs.zigDeps} "$ZIG_GLOBAL_CACHE_DIR/p"
          '';

          buildPhase = ''
            runHook preBuild
            zig build ${zig-target-flags} -Dcpu=baseline -Doptimize=ReleaseSafe
            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall
            zig build install ${zig-target-flags} -Dcpu=baseline -Doptimize=ReleaseSafe --prefix "$out"
            runHook postInstall
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
      }
    );
}

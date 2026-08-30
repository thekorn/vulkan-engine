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
        zig = zig-overlay.packages.${system}."master-2026-07-29";
        zig-target = "${pkgs.stdenv.targetPlatform.system}-${pkgs.stdenv.targetPlatform.parsed.abi.name}";
        zig-target-flags =
          "-Dtarget=${zig-target}"
          + pkgs.lib.optionalString pkgs.stdenv.isLinux " -Ddynamic-linker=${pkgs.stdenv.cc.bintools.dynamicLinker}";
        zig-cov = pkgs.stdenv.mkDerivation {
          pname = "zig-cov";
          version = "0.1.0";
          src = zcov-src;

          nativeBuildInputs = [ zig ];

          configurePhase = ''
            runHook preConfigure
            export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-cache"
            mkdir -p "$ZIG_GLOBAL_CACHE_DIR"
            runHook postConfigure
          '';

          buildPhase = ''
            runHook preBuild
            zig build ${zig-target-flags} -Doptimize=ReleaseSafe
            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall
            mkdir -p "$out/bin" "$out/lib"
            cp zig-out/bin/zig-cov "$out/bin/"
            cp zig-out/lib/zig-cov-rt.o "$out/lib/"
            runHook postInstall
          '';
        };
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
            pkgs.autoPatchelfHook
            pkgs.pkg-config
            pkgs.shaderc
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

        devShell = pkgs.mkShell {
          buildInputs =
            with pkgs;
            [
              zig
              zig-cov
              codebook
              cloc
              shaderc
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

          NIX_DYNAMIC_LINKER = pkgs.lib.optionalString pkgs.stdenv.isLinux pkgs.stdenv.cc.bintools.dynamicLinker;
          NIX_ZIG_TARGET = zig-target;
          LD_LIBRARY_PATH = pkgs.lib.optionalString pkgs.stdenv.isLinux (
            pkgs.lib.makeLibraryPath [
              pkgs.glfw
              pkgs.libGL
              pkgs.tinyobjloader
              pkgs.vulkan-loader
            ]
          );
          VK_LAYER_PATH = "${pkgs.vulkan-validation-layers}/share/vulkan/explicit_layer.d";
        };
      }
    );
}

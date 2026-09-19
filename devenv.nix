{ pkgs, inputs, lib, ... }:
let
  toolchain = import ./nix/toolchain.nix {
    inherit pkgs;
    inherit (inputs) zig-overlay zcov-src;
  };
in
{
  packages = with pkgs; [
    toolchain.zig
    toolchain.zig-cov
    codebook
    cloc
    shaderc
    pkg-config
    glfw
    vulkan-headers
    vulkan-loader.dev
    vulkan-loader
    vulkan-validation-layers
    tinyobjloader
  ] ++ lib.optionals stdenv.isLinux [ libGL.dev libGL ];

  enterShell = ''
    alias zed='zeditor'
  '';

  env = {
    NIX_DYNAMIC_LINKER = lib.optionalString pkgs.stdenv.isLinux pkgs.stdenv.cc.bintools.dynamicLinker;
    NIX_ZIG_TARGET = toolchain.zig-target;
    LD_LIBRARY_PATH = lib.optionalString pkgs.stdenv.isLinux (lib.makeLibraryPath [
      pkgs.glfw
      pkgs.libGL
      pkgs.tinyobjloader
      pkgs.vulkan-loader
    ]);
    VK_LAYER_PATH = "${pkgs.vulkan-validation-layers}/share/vulkan/explicit_layer.d";
  };
}

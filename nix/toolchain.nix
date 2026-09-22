{ pkgs, zig-overlay, zcov-src }:
let
  zig = zig-overlay.packages.${pkgs.stdenv.hostPlatform.system}."master-2026-09-20".overrideAttrs (old: {
    # The build runner keeps a slice into a temporary target query when adding
    # --dynamic-linker. Copy it into the command's arena so it survives until
    # process launch. Remove this workaround once the pinned Zig fixes it.
    installPhase = old.installPhase + ''
      substituteInPlace "$out/lib/compiler/Maker/Step/Compile.zig" \
        --replace-fail \
        'zig_args.appendAssumeCapacity(dynamic_linker_path);' \
        'zig_args.appendAssumeCapacity(try arena.dupe(u8, dynamic_linker_path));'
    '';
  });
  zig-target =
    if pkgs.stdenv.hostPlatform.isDarwin then
      "${pkgs.stdenv.targetPlatform.parsed.cpu.name}-macos-none"
    else
      "${pkgs.stdenv.targetPlatform.system}-${pkgs.stdenv.targetPlatform.parsed.abi.name}";
  zig-target-flags =
    "-Dtarget=${zig-target}"
    + pkgs.lib.optionalString pkgs.stdenv.hostPlatform.isLinux " -Ddynamic-linker=${pkgs.stdenv.cc.bintools.dynamicLinker}";
in
{
  inherit zig zig-target zig-target-flags;
  zig-cov = pkgs.stdenv.mkDerivation {
    pname = "zig-cov";
    version = "0.1.0";
    src = zcov-src;

    nativeBuildInputs = [ zig ] ++ pkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux [ pkgs.autoPatchelfHook ];
    buildInputs = pkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux [ pkgs.stdenv.cc.libc ];
    autoPatchelfFlags = pkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux [ "--keep-libc" ];

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
}

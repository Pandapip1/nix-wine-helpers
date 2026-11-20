{ stdenv, lib }:
stdenv.mkDerivation {
  pname = "nix-wine-exec";
  version = "0.1";
  src = ../src;
  buildPhase = ''
    runHook preBuild
    $CC -Wall -Wextra -O2 -o nix-wine-exec nix-wine-exec.c
    runHook postBuild
  '';
  installPhase = ''
    runHook preInstall
    install -Dm755 nix-wine-exec $out/bin/nix-wine-exec
    runHook postInstall
  '';
  meta = {
    description = "Run a command inside an unprivileged, detached overlayfs of a read-only wine prefix";
    platforms = lib.platforms.linux;
    mainProgram = "nix-wine-exec";
  };
}

{ stdenv, lib }:
stdenv.mkDerivation {
  pname = "wine-determinism";
  version = "0.1";
  src = ../src;
  buildPhase = ''
    runHook preBuild
    $CC -Wall -Wextra -O2 -shared -fPIC -o libwine-determinism.so wine-determinism.c -ldl -lpthread
    runHook postBuild
  '';
  installPhase = ''
    runHook preInstall
    install -Dm755 libwine-determinism.so $out/lib/libwine-determinism.so
    runHook postInstall
  '';
  meta = {
    description = "LD_PRELOAD shim freezing wall-clock time and randomness for reproducible wine prefix builds";
    platforms = lib.platforms.linux;
  };
}

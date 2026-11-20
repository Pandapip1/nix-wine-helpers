# A hermetic end-to-end example: a mingw-built exe inside a bundled prefix.
{ pkgs, helpers }:
let
  helloExe = pkgs.pkgsCross.mingwW64.stdenv.mkDerivation {
    name = "hello-wine-exe";
    src = ./.;
    buildPhase = "$CC -O2 -o hello.exe hello.c";
    installPhase = "install -Dm755 hello.exe $out/hello.exe";
  };

  prefix = helpers.mkWinePrefix {
    name = "hello-prefix";
    files."Program Files/Hello" = helloExe;
  };
in
helpers.mkWineApp {
  pname = "hello-wine";
  inherit prefix;
  exe = "C:\\Program Files\\Hello\\hello.exe";
  desktopName = "Hello (wine)";
}

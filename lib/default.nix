# Instantiate the helpers for a given nixpkgs.
#   helpers = import ./lib { inherit pkgs; };               # default wine
#   helpers = import ./lib { inherit pkgs; wine = ...; };   # custom wine
{ pkgs, wine ? pkgs.wineWow64Packages.stable }:
let
  nix-wine-exec = pkgs.callPackage ../pkgs/nix-wine-exec.nix { };
  wine-determinism = pkgs.callPackage ../pkgs/wine-determinism.nix { };
in
{
  inherit nix-wine-exec wine-determinism;
  mkWinePrefix = pkgs.callPackage ./mk-wine-prefix.nix { defaultWine = wine; patchBuildWine = import ./wine-build-fixes.nix; inherit wine-determinism; };
  mkWineApp = pkgs.callPackage ./mk-wine-app.nix { defaultWine = wine; inherit nix-wine-exec; };
}

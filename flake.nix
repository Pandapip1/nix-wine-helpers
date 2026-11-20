{
  description = "Helpers for packaging Windows software with a bundled wineprefix";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" ];
      forAll = f: nixpkgs.lib.genAttrs systems (s: f nixpkgs.legacyPackages.${s});
    in
    {
      # self.lib.mkHelpers pkgs -> { mkWinePrefix, mkWineApp, nix-wine-exec }
      lib = {
        mkHelpers = pkgs: import ./lib { inherit pkgs; };
      };

      overlays.default = final: _prev: {
        nixWineHelpers = import ./lib { pkgs = final; };
      };

      packages = forAll (pkgs:
        let h = self.lib.mkHelpers pkgs; in {
          inherit (h) nix-wine-exec wine-determinism;
          default = h.nix-wine-exec;
          example-hello = import ./examples/hello { inherit pkgs; helpers = h; };
        });
    };
}

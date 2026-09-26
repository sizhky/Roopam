{
  description = "Roopam - custom Finder folder icons and Favorites sidebar glyphs for macOS";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachSystem [ "aarch64-darwin" ] (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        roopam = pkgs.callPackage ./nix/default.nix { };
      in
      {
        packages = {
          default = roopam;
          roopam = roopam;
        };

        apps.default = {
          type = "app";
          program = "${roopam}/Applications/Roopam.app/Contents/MacOS/Roopam";
        };
      }
    );
}

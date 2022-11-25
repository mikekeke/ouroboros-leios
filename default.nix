let
  nixpkgsPin = {
    url =
      "https://github.com/nixos/nixpkgs/archive/ce6aa13369b667ac2542593170993504932eb836.tar.gz";
    sha256 = "0d643wp3l77hv2pmg2fi7vyxn4rwy0iyr8djcw1h5x72315ck9ik";
  };
  pkgs = import (builtins.fetchTarball nixpkgsPin) { };

in pkgs.mkShell {
  buildInputs = with pkgs; [
    ghc
    cabal-install
    haskell-language-server
    nixpkgs-fmt
    gtk3
    pkg-config
    haskellPackages.cabal-fmt
    haskellPackages.fourmolu
    haskellPackages.implicit-hie
  ];
  LANG = "C.UTF-8";
}

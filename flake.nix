{
  description = "Zig development environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    zig-overlay.url = "github:mitchellh/zig-overlay";
    zls-overlay.url = "github:zigtools/zls";
  };

  outputs = { self, nixpkgs, zig-overlay, zls-overlay }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
    in
    {
      devShells.${system}.default = pkgs.mkShell {
        packages = [
          zig-overlay.packages.${system}.master
          zls-overlay.packages.${system}.default
          pkgs.python312
          pkgs.python312Packages.pip
          pkgs.python312Packages.transformers
          pkgs.python312Packages.torch
        ];

        shellHook = ''
          export PATH="$PWD/zig-out/bin:$PATH"
        '';
      };
    };
}


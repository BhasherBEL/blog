{
  description = "Bhasher's blog";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    self.submodules = true;
  };

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems f;
    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          default = pkgs.stdenv.mkDerivation {
            pname = "blog";
            version = self.shortRev or "dirty";
            src = self;

            nativeBuildInputs = [ pkgs.hugo ];

            buildPhase = ''
              hugo --minify --gc
            '';

            installPhase = ''
              cp -r public $out
            '';
          };
        }
      );

      devShells = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          default = pkgs.mkShell {
            packages = [ pkgs.hugo ];
            shellHook = ''
              echo "Hugo $(hugo version)"
              echo "Run 'hugo server -D' to preview with drafts"
            '';
          };
        }
      );
    };
}

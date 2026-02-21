{
  description = "Bhasher's blog";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";

    hugo-blog-awesome = {
      url = "github:hugo-sid/hugo-blog-awesome";
      flake = false;
    };

    plausible-hugo = {
      url = "github:divinerites/plausible-hugo";
      flake = false;
    };
  };

  outputs =
    { self, ... }@inputs:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems = f: inputs.nixpkgs.lib.genAttrs systems f;
    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = inputs.nixpkgs.legacyPackages.${system};
        in
        {
          default = pkgs.stdenv.mkDerivation {
            pname = "blog";
            version = self.shortRev or "dirty";
            src = self;

            nativeBuildInputs = [ pkgs.hugo ];

            buildPhase = ''
              mkdir -p themes/hugo-blog-awesome themes/plausible-hugo
              cp -r ${inputs.hugo-blog-awesome}/. themes/hugo-blog-awesome/
              cp -r ${inputs.plausible-hugo}/. themes/plausible-hugo/
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
          pkgs = inputs.nixpkgs.legacyPackages.${system};
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

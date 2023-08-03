{self, ...}: {
  perSystem = {pkgs, ...}: {
    checks.lint =
      pkgs.runCommand "lint" {
        nativeBuildInputs = with pkgs; [
          statix
          deadnix
        ];
      } ''
        set -euo pipefail

        cd ${self}

        deadnix -f

        statix check

        touch $out
      '';
  };
}

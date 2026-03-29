{self, ...}: {
  perSystem = {
    lib,
    pkgs,
    system,
    ...
  }:
    lib.optionalAttrs (system == "x86_64-linux") {
      checks.yamlfmt = pkgs.runCommand "yamlfmt-check" {
        nativeBuildInputs = [pkgs.yamlfmt];
      } ''
        cd ${self}
        if [ ! -f .yamlfmt ]; then
          echo "ERROR: .yamlfmt config file not found in source!"
          exit 1
        fi
        yamlfmt -lint k8s/
        touch $out
      '';
    };
}

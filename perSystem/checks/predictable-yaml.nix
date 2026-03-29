{self, ...}: {
  perSystem = {
    lib,
    pkgs,
    inputs',
    system,
    ...
  }:
    lib.optionalAttrs (system == "x86_64-linux") {
      checks.predictable-yaml = pkgs.runCommand "predictable-yaml-check" {
        nativeBuildInputs = [inputs'.predictable-yaml.packages.default];
      } ''
        cd ${self}
        predictable-yaml lint k8s
        touch $out
      '';
    };
}

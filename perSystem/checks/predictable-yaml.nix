{self, ...}: {
  perSystem = {
    lib,
    pkgs,
    inputs',
    system,
    ...
  }: let
    predictable-yaml-configs-version =
      (builtins.fromJSON (builtins.readFile "${self}/flake.lock")).nodes.predictable-yaml-configs.original.ref;
  in
    lib.optionalAttrs (system == "x86_64-linux") {
      checks.predictable-yaml =
        pkgs.runCommand "predictable-yaml-check" {
          nativeBuildInputs = [inputs'.predictable-yaml.packages.default];
        } ''
          cp -r ${self} src
          chmod -R u+w src
          mkdir -p "src/.predictable-yaml/.cache/github.com/snarlysodboxer/predictable-yaml-configs/${predictable-yaml-configs-version}"
          cp ${self.inputs.predictable-yaml-configs}/*.yaml "src/.predictable-yaml/.cache/github.com/snarlysodboxer/predictable-yaml-configs/${predictable-yaml-configs-version}/"
          cd src
          predictable-yaml lint k8s
          touch $out
        '';
    };
}

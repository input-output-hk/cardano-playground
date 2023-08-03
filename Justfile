set shell := ["nu", "-c"]
set positional-arguments

default:
  just --list

apply-all:
  colmena apply --verbose

apply *ARGS:
  colmena apply --verbose --on {{ARGS}}

ssh HOSTNAME *ARGS:
  #!/usr/bin/env nu
  if not ('.ssh_config' | path exists) {
    print "Please run terraform first to create the .ssh_config file"
    exit 1
  }

  ssh -F .ssh_config {{HOSTNAME}} {{ARGS}}

bootstrap-ssh HOSTNAME *ARGS:
  #!/usr/bin/env nu
  if not ('.ssh_config' | path exists) {
    print "Please run terraform first to create the .ssh_config file"
    exit 1
  }

  if not ('.ssh_key' | path exists) {
    just save-bootstrap-ssh-key
  }

  ssh -F .ssh_config -i .ssh_key {{HOSTNAME}} {{ARGS}}

save-bootstrap-ssh-key:
  #!/usr/bin/env nu
  print "Retrieving ssh key from terraform..."
  let tf = (terraform show -json | from json)
  let key = ($tf.values.root_module.resources | where type == tls_private_key and name == bootstrap)
  $key.values.private_key_openssh | save .ssh_key
  chmod 0600 .ssh_key

cf STACKNAME:
  mkdir cloudFormation
  nix eval --json '.#cloudFormation.{{STACKNAME}}' | jq | save --force 'cloudFormation/{{STACKNAME}}.json'
  rain deploy --termination-protection --yes ./cloudFormation/{{STACKNAME}}.json

wg-genkey KMS HOSTNAME:
  #!/usr/bin/env nu
  let private = 'secrets/wireguard_{{HOSTNAME}}.enc'
  let public = 'secrets/wireguard_{{HOSTNAME}}.txt'

  if not ($private | path exists) {
    wg genkey | sops --kms "{{KMS}}" -e /dev/stdin | save $private
    git add $private
  }

  if not ($public | path exists) {
    sops -d $private | wg pubkey | save $public
    git add $public
  }

wg-genkeys:
  #!/usr/bin/env nu
  let nodes = (nix eval --json '.#nixosConfigurations' --apply builtins.attrNames | from json)
  let kms = (nix eval --raw '.#cluster.kms')
  for node in $nodes { just wg-genkey $kms $node }

bootstrap HOSTNAME:
  nix run '.#bootstrap' -- --verbose --flake '.#{{HOSTNAME}}'

terraform *ARGS:
  rm --force cluster.tf.json
  nix build .#terraform.cluster --out-link cluster.tf.json
  terraform {{ARGS}}

alias tf := terraform

set shell := ["nu", "-c"]
set positional-arguments

alias tf := terraform

default:
  just --list

apply *ARGS:
  colmena apply --verbose --on {{ARGS}}

apply-all:
  colmena apply --verbose

cf STACKNAME:
  mkdir cloudFormation
  nix eval --json '.#cloudFormation.{{STACKNAME}}' | jq | save --force 'cloudFormation/{{STACKNAME}}.json'
  rain deploy --termination-protection --yes ./cloudFormation/{{STACKNAME}}.json

save-bootstrap-ssh-key:
  #!/usr/bin/env nu
  print "Retrieving ssh key from terraform..."
  let tf = (terraform show -json | from json)
  let key = ($tf.values.root_module.resources | where type == tls_private_key and name == bootstrap)
  $key.values.private_key_openssh | save .ssh_key
  chmod 0600 .ssh_key

show-nameservers:
  #!/usr/bin/env bash
  DOMAIN=$(nix eval --raw '.#cluster.domain')
  ID=$(aws route53 list-hosted-zones-by-name | jq --arg DOMAIN "$DOMAIN" -r '.HostedZones[] | select(.Name | startswith($DOMAIN)).Id')
  NS=$(aws route53 list-resource-record-sets --hosted-zone-id "$ID" | jq -r '.ResourceRecordSets[] | select(.Type == "NS").ResourceRecords[].Value')
  echo "Nameservers for the following hosted zone need to be added to the NS record of the delegating authority"
  echo "Nameservers for domain: $DOMAIN (hosted zone id: $ID) are:"
  echo "$NS"

ssh HOSTNAME *ARGS:
  #!/usr/bin/env nu
  if not ('.ssh_config' | path exists) {
    print "Please run terraform first to create the .ssh_config file"
    exit 1
  }

  ssh -F .ssh_config {{HOSTNAME}} {{ARGS}}

ssh-bootstrap HOSTNAME *ARGS:
  #!/usr/bin/env nu
  if not ('.ssh_config' | path exists) {
    print "Please run terraform first to create the .ssh_config file"
    exit 1
  }

  if not ('.ssh_key' | path exists) {
    just save-bootstrap-ssh-key
  }

  ssh -F .ssh_config -i .ssh_key {{HOSTNAME}} {{ARGS}}

terraform *ARGS:
  rm --force cluster.tf.json
  nix build .#terraform.cluster --out-link cluster.tf.json
  terraform {{ARGS}}

wg-genkey KMS HOSTNAME:
  #!/usr/bin/env nu
  let private = 'secrets/wireguard_{{HOSTNAME}}.enc'
  let public = 'secrets/wireguard_{{HOSTNAME}}.txt'

  if not ($private | path exists) {
    print $"Generating ($private) ..."
    wg genkey | sops --kms "{{KMS}}" -e /dev/stdin | save $private
    git add $private
  }

  if not ($public | path exists) {
    print $"Deriving ($public) ..."
    sops -d $private | wg pubkey | save $public
    git add $public
  }

wg-genkeys:
  #!/usr/bin/env nu
  let nodes = (nix eval --json '.#nixosConfigurations' --apply builtins.attrNames | from json)
  let kms = (nix eval --raw '.#cluster.kms')
  for node in $nodes { just wg-genkey $kms $node }

set shell := ["nu", "-c"]
set positional-arguments

alias tf := terraform

default:
  @just --list

# ----------
# New recipes

test:
  #!/usr/bin/env bash
  nohup sleep 60 &
  sleep 60

run:
  #!/usr/bin/env bash
  just stop

  echo "Cleaning state-demo..."
  if [ -d state-demo ]; then
    chmod -R +w state-demo
    rm -rf state-demo
  fi

  echo "Generating state-demo config..."

  export DATA_DIR=state-demo
  export KEY_DIR=state-demo
  export TESTNET_MAGIC=42
  export PAYMENT_KEY=state-demo/utxo-keys/rich-utxo
  export NUM_GENESIS_KEYS=3
  export NUM_POOLS=3
  export START_INDEX=1
  export END_INDEX=3
  export GENESIS_DIR="$DATA_DIR"
  export BULK_CREDS=state-demo/bulk-creds.json
  export PAYMENT_KEY=state-demo/utxo-keys/rich-utxo
  export STAKE_POOL_DIR=state-demo/stake-pools
  export CARDANO_NODE_SOCKET_PATH=./node.socket
  # export DEBUG=1

  SECURITY_PARAM=8 \
    SLOT_LENGTH=200 \
    START_TIME=$(date --utc +"%Y-%m-%dT%H:%M:%SZ" --date " now + 30 seconds") \
    nix run .#job-gen-custom-node-config

  export PAYMENT_ADDRESS=$(cardano-cli address build --testnet-magic 42 --payment-verification-key-file "$PAYMENT_KEY".vkey)
  nix run .#job-create-stake-pool-keys
  cat state-demo/delegate-keys/bulk.creds.bft.json state-demo/stake-pools/bulk.creds.pools.json | jq -s > "$BULK_CREDS"

  echo "Start cardano-node in the background. Run \"just stop\" to stop"
  NODE_CONFIG=state-demo/node-config.json \
    NODE_TOPOLOGY=state-demo/topology.json \
    SOCKET_PATH=./node.socket \
    nohup setsid nix run .#run-cardano-node & echo $! > cardano.pid &
  echo "Sleeping 30 seconds until $(date -d  @$(($(date +%s) + 30)))"
  sleep 30
  echo

  echo "Moving genesis utxo..."
  BYRON_SIGNING_KEY=state-demo/utxo-keys/shelley.000.skey \
    ERA="--alonzo-era" \
    nix run .#job-move-genesis-utxo
  echo "Sleeping 7 seconds until $(date -d  @$(($(date +%s) + 7)))"
  sleep 7
  echo

  echo "Registering stake pools..."
  POOL_RELAY=sanchonet.local \
    POOL_RELAY_PORT=3001 \
    ERA="--alonzo-era" \
    nix run .#job-register-stake-pools
  echo "Sleeping 320 seconds until $(date -d  @$(($(date +%s) + 320)))"
  sleep 320
  echo

  echo "Forking to babbage..."
  just sync-status
  MAJOR_VERSION=7 \
    ERA="--alonzo-era" \
    nix run .#job-update-proposal-hard-fork
  echo "Sleeping 320 seconds until $(date -d  @$(($(date +%s) + 320)))"
  sleep 320
  echo

  echo "Forking to babbage (intra-era)..."
  just sync-status
  MAJOR_VERSION=8 \
    ERA="--babbage-era" \
    nix run .#job-update-proposal-hard-fork
  echo "Sleeping 320 seconds until $(date -d  @$(($(date +%s) + 320)))"
  sleep 320
  echo

  echo "Forking to conway..."
  just sync-status
  MAJOR_VERSION=9 \
    ERA="--babbage-era" \
    nix run .#job-update-proposal-hard-fork
  echo "Sleeping 320 seconds until $(date -d  @$(($(date +%s) + 320)))"
  sleep 320
  echo

  just sync-status

stop:
  #!/usr/bin/env bash
  if [ -f cardano.pid ]; then
    echo Stopping cardano-node
    kill $(< cardano.pid) 2> /dev/null
    rm -f cardano.pid node.socket
  fi

sync-status:
  cardano-cli query tip --testnet-magic 42

query-rich-utxo:
  #!/usr/bin/env bash
  cardano-cli query utxo --testnet-magic 42 \
  --address $(cardano-cli address build --testnet-magic 42 --payment-verification-key-file state-demo/utxo-keys/rich-utxo.vkey)

query-gov-status:
  #!/usr/bin/env bash
  cardano-cli query governance ...

# ----------


apply *ARGS:
  colmena apply --verbose --on {{ARGS}}

apply-all *ARGS:
  colmena apply --verbose {{ARGS}}

build-machine MACHINE *ARGS:
  nix build -L .#nixosConfigurations.{{MACHINE}}.config.system.build.toplevel {{ARGS}}

build-machines *ARGS:
  #!/usr/bin/env nu
  let nodes = (nix eval --json '.#nixosConfigurations' --apply builtins.attrNames | from json)
  for node in $nodes { just build-machine $node {{ARGS}} }

lint:
  deadnix -f
  statix check

cf STACKNAME:
  mkdir cloudFormation
  nix eval --json '.#cloudFormation.{{STACKNAME}}' | from json | save --force 'cloudFormation/{{STACKNAME}}.json'
  rain deploy --debug --termination-protection --yes ./cloudFormation/{{STACKNAME}}.json

save-bootstrap-ssh-key:
  #!/usr/bin/env nu
  print "Retrieving ssh key from terraform..."
  let tf = (terraform show -json | from json)
  let key = ($tf.values.root_module.resources | where type == tls_private_key and name == bootstrap)
  $key.values.private_key_openssh | save .ssh_key
  chmod 0600 .ssh_key

show-flake *ARGS:
  nix flake show --allow-import-from-derivation {{ARGS}}

show-nameservers:
  #!/usr/bin/env nu
  let domain = (nix eval --raw '.#cardano-parts.cluster.infra.aws.domain')
  let zones = (aws route53 list-hosted-zones-by-name | from json).HostedZones
  let id = ($zones | where Name == $"($domain).").Id.0
  let sets = (aws route53 list-resource-record-sets --hosted-zone-id $id | from json).ResourceRecordSets
  let ns = ($sets | where Type == "NS").ResourceRecords.0.Value
  print "Nameservers for the following hosted zone need to be added to the NS record of the delegating authority"
  print $"Nameservers for domain: ($domain) \(hosted zone id: ($id)) are:"
  print ($ns | to text)

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

ssh-for-each *ARGS:
  #!/usr/bin/env nu
  let nodes = (nix eval --json '.#nixosConfigurations' --apply builtins.attrNames | from json)
  $nodes | par-each {|node| just ssh -q $node {{ARGS}}}

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
  let kms = (nix eval --raw '.#cardano-parts.cluster.infra.aws.kms')
  let nodes = (nix eval --json '.#nixosConfigurations' --apply builtins.attrNames | from json)
  for node in $nodes { just wg-genkey $kms $node }

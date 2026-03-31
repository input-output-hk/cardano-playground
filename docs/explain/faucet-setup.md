# Faucet Setup

The faucet software used is from:
[cardano-faucet](https://github.com/input-output-hk/cardano-faucet).

Each network faucet will need to have its own wallet mnemonic, address and a
json config file created and populated with the wallet mnemonic and appropriate
api keys, default limits, network, recaptcha and cors settings.

## Public Faucet URL
The faucet url the public can use to obtain funds is found at:
[https://docs.cardano.org/cardano-testnets/tools/faucet](https://docs.cardano.org/cardano-testnets/tools/faucet).

## Setup Files
New wallet mnemonics can be made from the ops shell with:
```bash
cardano-address recovery-phrase generate > faucet.mnemonic
```

The wallet address can be generated using cardano-address and or,
alternatively, by running the faucet daemon which will log the address.  To use
cli, the command is:
```bash
# just gen-payment-address FILE OFFSET="0"
#
# The OFFSET should be matched to the value of `address_index` in the faucet
# config file, which defaults to 0
just gen-payment-address faucet.mnemonic
```

New api keys can be generated with pwgen or from urandom:
```bash
pwgen -s -n 32
head -c 128 /dev/urandom | tr -dc 'a-zA-Z0-9' | head -c 32
```

The faucet config file is typically of the following form:
```json
{
        "debug": false,
        "api_keys": [
                {
                        "api_key": "$API_KEY1",
                        "lovelace": 10000200000,
                        "rate_limit": 60,
                        "delegate": true
                },
                {
                        "api_key": "$API_KEY2",
                        "lovelace": 10000200000,
                        "rate_limit": 86400,
                        "delegate": true
                }
        ],
        "recaptcha_limits": {
                "default": {
                        "api_key": "unused",
                        "lovelace": 10000200000,
                        "rate_limit": 86400,
                        "delegate": true
                }
        },
        "max_stake_key_index": 500,
        "delegation_utxo_size": 10,
        "mnemonic": [
                "MNEMONIC_WORD_1",
                "MNEMONIC_WORD_2",
                "MNEMONIC_WORD_3",
                ...
                "MNEMONIC_WORD_24"
        ],
        "network": {
                "Testnet": $TESTNET_MAGIC
        },
        "recaptcha_site_key": "$RECAPTCHA_SITE_KEY",
        "recaptcha_secret_key": "$RECAPTCHA_SECRET_KEY",
        "allowed_cors_origins": [
                "https://$ALLOWED_CORS_ORIGIN_EXAMPLE_FQDN",
        ],
        "address_index": 0
}
```

As general guidance, faucet pool delegation sizes, UTxO sizes, UTxO quantity
and `max_stake_key_index` values generally fall into one of the following
categories:
```
# Preview, Preprod:
Faucet UTxO:                 10000200000     # Funded via distribute.py, ~50,000 UTxO, below
Faucet Pool Delegation:      1000000000000   # Funded via setup-delegation-accounts.py, below
Faucet delegation_utxo_size: 10              # Via faucet config file
max_stake_key_index:         500             # Via faucet config file

# Historical Sanchonet, Dijkstra:
Faucet UTxO:                 100000200000    # Funded via distribute.py, ~10,000 UTxO, below
Faucet Pool Delegation:      10000000000000  # Funded via setup-delegation-accounts.py, below
Faucet delegation_utxo_size: 10              # Via faucet config file
max_stake_key_index:         99              # Via faucet config file
```

Files for faucet mnemonic, address and config file will need to be sops
encrypted and stored at appropriate locations in the secrets directories,
typically:
```bash
# Typical $ENV faucet secret locations for deploying to machine: $MACHINE
just sops-encrypt-binary secrets/envs/"$ENV"/utxo-keys/faucet.addr
just sops-encrypt-binary secrets/envs/"$ENV"/utxo-keys/faucet.mnemonic
just sops-encrypt-binary secrets/groups/"${ENV}"1/deploy/"$MACHINE"-faucet.json
```

## Filling the Faucet
Once these files are created, if the faucet is immediately deployed, logs will
show the following, where `10000200000` and `501` are the values faucet found
for `lovelace` and `max_stake_key_index + 1` in the config file it was given in
this example:
```bash
lovelace values for api keys [Ada (Lovelace 10000200000)]
faucet address: $WALLET_ADDRESS
UtxoStats (fromList [])
utxo set initialized
501 stake keys not registered, 0 stake keys registered and ready for use, 0 stake keys delegated to pools
```

Faucet now needs to be funded with UTxOs for ADA requests and pool delegations.
Pool delegation preparation also needs to be performed.  If not already
started, start a node for the environment of interest and set up your shell
environment:
```bash
just start-node "$ENV"
source <(just set-default-cardano-env "$ENV")
```

For general UTxO funding, a `rewards.json` file will needs to be prepared in
the following form, where the `$FAUCET_ADDRESS` is substituted, and the
lovelace value matches the lovelace value in the faucet config file.  The
number of array item lines should match the target number of UTxOs the faucet
should be funded with, example: 10,000.
```json
# rewards.json
[
  {"$FAUCET_ADDRESS":10000200000},
  {"$FAUCET_ADDRESS":10000200000},
  {"$FAUCET_ADDRESS":10000200000},
  ...
  {"$FAUCET_ADDRESS":10000200000}
]
```

Transactions which correspond to the above rewards file can be prepeared by
running the distribute script and providing the appropriate decrypted
environment funding rich key and rich key address:
```bash
NOMENU=true scripts/distribute.py \
  --testnet-magic "$TESTNET_MAGIC" \
  --signing-key-file <(just sops-decrypt-binary secrets/envs/"$ENV"/utxo-keys/rich-utxo.skey) \
  --address $(just sops-decrypt-binary secrets/envs/"$ENV"/utxo-keys/rich-utxo.addr) \
  --payments-json rewards.json
```

This script will create a number of transaction files in the current directory.
Before submitting them to the network, they can be examined if desired,
example:
```bash
cardano-cli debug transaction view --tx-file tx-payments-0-99.txsigned
```

Once satisfied the transactions look good and can be submitted, these can all
be submitted at once with the following command which should complete within a
few minutes, depending on the volume of transactions being submitted:
```bash
for i in $(ls -tr1 tx-payments*.txsigned); do
  echo "Submitting: $i"
  cardano-cli latest transaction submit --tx-file $i
  echo
done
```

Once the transactions are submitted, the transaction files can be deleted from
the local directory
```bash
rm *.tx*
```

Additional UTxOs will need to be prepared to support the faucet delegating funds to
pools.  A `delegation.json` file can be made for this, similar to the
`rewards.json` file above, except the lovelace value should match the
`delegation_utxo_size` value which is provided in ADA and the number of json
array items should match the `max_stake_key_index` value + 1 from the faucet config
file.  A typical example would be when `delegation_utxo_size` is `10`:
```json
# delegation.json
[
  {"$FAUCET_ADDRESS":10000000},
  {"$FAUCET_ADDRESS":10000000},
  {"$FAUCET_ADDRESS":10000000},
  ...
  {"$FAUCET_ADDRESS":10000000}
]
```

These delegation UTxOs transactions can be generated, submitted and cleaned up
using the same commands given above for the rewards.json UTxOs except the
delegation.json file is substituted for the rewards.json file.

Finally, the faucet pool delegations need to be prepared, which can be
accomplished with the following command.  The number of accounts used in this
command should match the `max_stake_key_index` value + 1 from the faucet config
file.  Note that the default delegation amount is 10M ADA.  This can be changed
by using the `-d --delegation-amount <INT>` option (in lovelace) if desired.

This command will automatically submit transactions to the network immediately,
be sure you have the parameters correct!
```bash
NOMENU=true scripts/setup-delegation-accounts.py \
  --testnet-magic "$TESTNET_MAGIC" \
  --signing-key-file <(just sops-decrypt-binary secrets/envs/"$ENV"/utxo-keys/rich-utxo.skey) \
  --wallet-mnemonic <(just sops-decrypt-binary secrets/envs/"$ENV"/utxo-keys/faucet.mnemonic) \
  --num-accounts 501
```

Clean up of residual transaction files for the pool delegation account set up
is similar to the distribution script clean up above.

Once these UTxO and pool delegation transactions have been submitted, the
faucet daemon can be restarted with `systemctl restart cardano-faucet` and upon
restart, the logs should now show populated UTxOs and pool delegations are
ready:
```bash
lovelace values for api keys [Ada (Lovelace 10000200000)]
faucet address: $WALLET_ADDRESS
UtxoStats (fromList [(Ada (Lovelace 10000000),501),(Ada (Lovelace 10000200000),10000)])
utxo set initialized
0 stake keys not registered, 501 stake keys registered and ready for use, 0 stake keys delegated to pools
```

## Accessing the Faucet
For cardano-playground, the faucet UI and curl endpoint will be the following.
API key usage may be optional, depending on the faucet configuration file.
```bash
# Faucet UI:
https://faucet.$ENV.play.dev.cardano.org/basic-faucet

# Curl:
curl -v "https://faucet.$ENV.play.dev.cardano.org/send-money?address=$SEND_ADDRESS&api_key=$API_KEY"
```

## Refilling the Faucet
When the faucet runs low on UTxOs, the same procedures above can be re-used to add more UTxOs.

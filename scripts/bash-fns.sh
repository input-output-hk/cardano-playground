# shellcheck disable=SC2148
#
# Various bash helper functions live here.


# This can be used to simplify ssh sessions, rsync, ex:
#   ssh -o "$(ssm-proxy-cmd "$REGION")" "$INSTANCE_ID"
ssm-proxy-cmd() {
  echo "ProxyCommand=sh -c 'aws --region $1 ssm start-session --target %h --document-name AWS-StartSSHSession --parameters portNumber=%p'"
}


# A handy transaction submission function with mempool monitoring.
# CARDANO_NODE_{NETWORK_ID,SOCKET_PATH}, TESTNET_MAGIC should already be exported.
submit() (
  set -euo pipefail
  TX_SIGNED="$1"

  TXID=$(cardano-cli latest transaction txid --tx-file "$TX_SIGNED")

  echo "Submitting $TX_SIGNED with txid $TXID..."
  cardano-cli latest transaction submit --tx-file "$TX_SIGNED"

  EXISTS="true"
  while [ "$EXISTS" = "true" ]; do
    EXISTS=$(cardano-cli latest query tx-mempool tx-exists "$TXID" | jq -r .exists)
    if [ "$EXISTS" = "true" ]; then
      echo "The transaction still exists in the mempool, sleeping 5s: $TXID"
    else
      echo "The transaction has been removed from the mempool."
    fi
    sleep 5
  done
  echo "Transaction $TX_SIGNED with txid $TXID submitted successfully."
  echo
)

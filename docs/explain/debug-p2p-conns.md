# Debug peer to peer connections

Cardano-node can generate peer to peer connection information by issuing a
sigusr1 to the node process
```bash
# Generate raw p2p networking state info
pkill --echo --signal SIGUSR1 cardano-node

# Or...
# Alternatively, issue the alias command available in cardano-parts node deployed machines:
cardano-show-p2p-conns
```

Peer to peer connection info will get logged to the default logger which in
cardano-parts deployments will be journald.  Save this state:
```bash
journalctl -S -1m -g TrState --no-pager > trstate-raw.txt
```

The peer to peer state info is not in json or other easy to use format, so
clean it up a bit into something easier to work with:
```bash
# Clean up the output format
sed -E \
  -e 's/.*TrState \(fromList \[//' \
  -e 's/.{2}$//g' \
  -e 's/\),/\)\n/g' \
  trstate-raw.txt \
  | tr -d '()' \
  | awk -F ',' '{printf("%-32s|  %s\n", $2, $1)}' \
  | sort > ip-list.txt
```

Apart from reviewing the full sanitized ip list, other examples of using this
peer to peer state info might include:

Use the sanitized peer to peer state info to check quantities of connection types
```bash
# Get a summary of p2p conn types:
cat ip-list.txt | awk -F '|' '{print $1}' | uniq -c | sort -nr
    103 InboundSt Duplex
     40 OutboundDupSt Expired
     11 OutboundUniSt
      8 DuplexSt
      4 InboundSt Unidirectional
```

Or, check the total number of ephemeral port inbound duplex connections
```bash
cat ip-list.txt | grep 'InboundSt Duplex' | grep -E ':[0-9]{5}' | wc -l
44
```

#!/usr/bin/env nix
#!nix shell nixpkgs#bashInteractive nixpkgs#bc --command bash
# shellcheck shell=bash
set -euo pipefail

# Purpose:
#   Bare minimum script for querying gov state action pass/fail status

# Assume all binaries required are already in the CLI path
# Assume we are online
# Assume we are on the proper network
# Assume we are at tip
# Assume we are in the conway era or later
# Assume we are querying a gov action
# Assume the gov action id and index are valid

# Assume arg params to the command will be:
#
# $0 $ACTION_UTXO $ACTION_IDX

[ -n "${DEBUG:-}" ] && set -x

# ANSI color setup
BLUE="\e[94m"
CYAN="\e[36m"
GREEN="\e[92m"
OFF="\e[0m"
RED="\e[91m"
GREEN_CHECK="$GREEN✅"
RED_X="$RED❌"

# Arg setup
ACTION_UTXO="$1"
ACTION_IDX="$2"
ACTION_ID="$ACTION_UTXO$(printf "%02x\n" "$ACTION_IDX")"
ACTION_BECH=$(bech32 gov_action <<< "$ACTION_ID")

# Basic query info
echo "Current voting status for:"
echo "  ACTION_ID: $ACTION_ID"
echo "  ACTION_BECH: $ACTION_BECH"
echo

GOV_STATE=$(cardano-cli latest query gov-state 2> /dev/stdout)
ACTION_STATE=$(jq -r ".proposals | to_entries[] | .value" 2> /dev/null <<< "$GOV_STATE")
ACTION=$(jq -r ". | select(.actionId.txId == \"$ACTION_UTXO\" and .actionId.govActionIx == $ACTION_IDX)" 2> /dev/null <<< "$ACTION_STATE")

DREP_DIST=$(cardano-cli latest query drep-stake-distribution --all-dreps 2> /dev/stdout)
DREP_STAKE_TOTAL=$(jq -r '[del(.[] | select(.[0] == "drep-alwaysAbstain" or .[0] == "drep-alwaysNoConfidence")) | .[][1]] | add' <<< "$DREP_DIST" 2> /dev/null)
DREP_NOCONF_TOTAL=$(jq -r '(.[] | select(.[0] == "drep-alwaysNoConfidence") | .[1]) // 0' <<< "$DREP_DIST" 2> /dev/null)
echo "Some potentially useful metrics:"
echo "  DREP_STAKE_TOTAL: $DREP_STAKE_TOTAL"
echo "  DREP_NOCONF_TOTAL: $DREP_NOCONF_TOTAL"

POOL_DIST=$(cardano-cli latest query spo-stake-distribution --all-spos 2> /dev/stdout)
POOL_STAKE_TOTAL=$(jq -r '[.[][1]] | add' <<< "$POOL_DIST" 2> /dev/null)
echo "  POOL_STAKE_TOTAL: $POOL_STAKE_TOTAL"

COMMITTEE_DIST=$(cardano-cli latest query committee-state \
  | jq -r '
    [ .committee | (to_entries[] | select(.value.hotCredsAuthStatus.tag == "MemberAuthorized") |
      [
        "\(.value.hotCredsAuthStatus.contents | keys[0])-\(.value.hotCredsAuthStatus.contents.keyHash // .value.hotCredsAuthStatus.contents.scriptHash)",
        (if .value.hotCredsAuthStatus.tag == "MemberAuthorized" then 1 else 0 end)
      ]
    )
  ]' 2> /dev/null || true)

if [ "$COMMITTEE_DIST" == "" ]; then
  COMMITTEE_DIST="[]"
fi

COMMITTEE_TOTAL=$(jq -r "([.[][1]] | add) // 0" <<< "$COMMITTEE_DIST" 2> /dev/null)
COMMITTEE_THRESHOLD=$(jq -r '"\(.committee.threshold)" // 0' <<< "$GOV_STATE" 2> /dev/null)
COMMITTEE_THRESHOLD_TYPE=$(jq -r "type" <<< "$COMMITTEE_THRESHOLD" 2> /dev/null)
echo "  COMMITTEE_TOTAL: $COMMITTEE_TOTAL"

case "$COMMITTEE_THRESHOLD_TYPE" in
  "object")
    {
      read -r numerator
      read -r denominator
    } <<< "$(jq -r '.numerator // "-", .denominator // "-"' <<< "$COMMITTEE_THRESHOLD")"
    COMMITTEE_THRESHOLD=$(bc <<< "scale=2; 100.00 * ${numerator} / ${denominator}")
    ;;

  "number")
    COMMITTEE_THRESHOLD=$(bc <<< "scale=2; 100.00 * $COMMITTEE_THRESHOLD")
    ;;
esac

PPARAMS=$(cardano-cli latest query protocol-parameters)
PROT_MAJOR_VER=$(jq -r ".protocolVersion.major // -1" <<< "$PPARAMS" 2> /dev/null)
echo "  PROT_MAJOR_VER: $PROT_MAJOR_VER"

{
  read -r ACTION_TAG
  read -r ACTION_CONTENTS
  read -r ACTION_ANCHOR_URL
  read -r ACTION_ANCHOR_HASH
  read -r ACTION_PROPOSED_IN_EPOCH
  read -r ACTION_EXPIRES_AFTER_EPOCH
  read -r ACTION_DEPOSIT_RETURN_KEY_TYPE
  read -r ACTION_DEPOSIT_RETURN_HASH
  read -r ACTION_DEPOSIT_RETURN_NETWORK
  read -r ACTION_DREP_VOTE_YES_COUNT
  read -r ACTION_DREP_VOTE_NO_COUNT
  read -r ACTION_DREP_ABSTAIN_COUNT
  read -r ACTION_POOL_VOTE_YES_COUNT
  read -r ACTION_POOL_VOTE_NO_COUNT
  read -r ACTION_POOL_ABSTAIN_COUNT
  read -r ACTION_COMMITTEE_VOTE_YES_COUNT
  read -r ACTION_COMMITTEE_VOTE_NO_COUNT
  read -r ACTION_COMMITTEE_ABSTAIN_COUNT
} <<< "$(jq -r '
  .proposalProcedure.govAction.tag // "-",
  "\(.proposalProcedure.govAction.contents)" // "-",
  .proposalProcedure.anchor.url // "-",
  .proposalProcedure.anchor.dataHash // "-",
  .proposedIn // "-",
  .expiresAfter // "-",
  (.proposalProcedure.returnAddr.credential|keys[0]) // "-",
  (.proposalProcedure.returnAddr.credential|flatten[0]) // "-",
  .proposalProcedure.returnAddr.network // "-",
  (.dRepVotes | with_entries(select(.value | contains("Yes"))) | length),
  (.dRepVotes | with_entries(select(.value | contains("No"))) | length),
  (.dRepVotes | with_entries(select(.value | contains("Abstain"))) | length),
  (.stakePoolVotes | with_entries(select(.value | contains("Yes"))) | length),
  (.stakePoolVotes | with_entries(select(.value | contains("No"))) | length),
  (.stakePoolVotes | with_entries(select(.value | contains("Abstain"))) | length),
  (.committeeVotes | with_entries(select(.value | contains("Yes"))) | length),
  (.committeeVotes | with_entries(select(.value | contains("No"))) | length),
  (.committeeVotes | with_entries(select(.value | contains("Abstain"))) | length)' <<< "$ACTION")"

  echo "  ACTION_TAG: $ACTION_TAG"
  echo "  ACTION_ANCHOR_URL: $ACTION_ANCHOR_URL"
  echo "  ACTION_ANCHOR_HASH: $ACTION_ANCHOR_HASH"
  echo "  ACTION_PROPOSED_IN_EPOCH: $ACTION_PROPOSED_IN_EPOCH"
  echo "  ACTION_EXPIRES_AFTER_EPOCH: $ACTION_EXPIRES_AFTER_EPOCH"
  echo "  ACTION_DEPOSIT_RETURN_KEY_TYPE: $ACTION_DEPOSIT_RETURN_KEY_TYPE"
  echo "  ACTION_DEPOSIT_RETURN_HASH: $ACTION_DEPOSIT_RETURN_HASH"
  echo "  ACTION_DEPOSIT_RETURN_NETWORK: $ACTION_DEPOSIT_RETURN_NETWORK"
  echo "  ACTION_DREP_VOTE_YES_COUNT: $ACTION_DREP_VOTE_YES_COUNT"
  echo "  ACTION_DREP_VOTE_NO_COUNT: $ACTION_DREP_VOTE_NO_COUNT"
  echo "  ACTION_DREP_ABSTAIN_COUNT: $ACTION_DREP_ABSTAIN_COUNT"
  echo "  ACTION_POOL_VOTE_YES_COUNT: $ACTION_POOL_VOTE_YES_COUNT"
  echo "  ACTION_POOL_VOTE_NO_COUNT: $ACTION_POOL_VOTE_NO_COUNT"
  echo "  ACTION_POOL_ABSTAIN_COUNT: $ACTION_POOL_ABSTAIN_COUNT"
  echo "  ACTION_COMMITTEE_VOTE_YES_COUNT: $ACTION_COMMITTEE_VOTE_YES_COUNT"
  echo "  ACTION_COMMITTEE_VOTE_NO_COUNT: $ACTION_COMMITTEE_VOTE_NO_COUNT"
  echo "  ACTION_COMMITTEE_ABSTAIN_COUNT: $ACTION_COMMITTEE_ABSTAIN_COUNT"

  # Generate lists with the DRep hashes that are voted yes, no or abstain.
  # Add a 'drep-' in front of each entry to mach up the syntax in the `drep-stake-distribution` json.
  {
    read -r DREP_HASH_YES
    read -r DREP_HASH_ABSTAIN
  } <<< "$(jq -r '
    "\(.dRepVotes | with_entries(select(.value | contains("Yes"))) | keys | ["drep-\(.[])"] )",
    "\(.dRepVotes | with_entries(select(.value | contains("Abstain"))) | keys | ["drep-\(.[])"])"
  ' <<< "$ACTION" 2> /dev/null)"

  {
    read -r DREP_STAKE_YES
    read -r DREP_STAKE_ABSTAIN
  } <<< "$(jq -r "
    ([ .[] | select(.[0]==${DREP_HASH_YES}[]) | .[1] ] | add) // 0,
    ([ .[] | select(.[0]==${DREP_HASH_ABSTAIN}[]) | .[1] ] | add) // 0
  " <<< "$DREP_DIST" 2> /dev/null)"

  # Calculate the acceptance percentage for the drep group
  if [ "$ACTION_TAG" != "NoConfidence" ]; then

    # Do a normal percentage calculation if not a `NoConfidence` action
    DREP_PCT=$(bc <<< "scale=2; 100.00 * $DREP_STAKE_YES / ($DREP_STAKE_TOTAL + $DREP_NOCONF_TOTAL - $DREP_STAKE_ABSTAIN)" 2> /dev/null)
    [ "$DREP_PCT" == "" ] && DREP_PCT="0"
  else
    # Or, if a NoConfidence action, the always no confidence counts as yes
    DREP_PCT=$(bc <<< "scale=2; 100.00 * ($DREP_STAKE_YES + $DREP_NOCONF_TOTAL) / ($DREP_STAKE_TOTAL - $DREP_STAKE_ABSTAIN)" 2> /dev/null)
  fi

  # Generate lists with the pool hashes that are voted yes, no or abstain.
  {
    read -r POOL_HASH_YES
    read -r POOL_HASH_ABSTAIN
  } <<< "$(jq -r '
    "\(.stakePoolVotes | with_entries(select(.value | contains("Yes"))) | keys )",
    "\(.stakePoolVotes | with_entries(select(.value | contains("Abstain"))) | keys)"
  ' <<< "$ACTION" 2> /dev/null)"

  # Calculate the total power of the yes, no and abstain keys
  {
    read -r POOL_STAKE_YES
    read -r POOL_STAKE_ABSTAIN
  } <<< "$(jq -r "
    ([ .[] | select(.[0]==${POOL_HASH_YES}[]) | .[1] ] | add) // 0,
    ([ .[] | select(.[0]==${POOL_HASH_ABSTAIN}[]) | .[1] ] | add) // 0
  " <<< "$POOL_DIST" 2> /dev/null)"

  # Calculate the acceptance percentage for the Pool group
  POOL_PCT=$(bc <<< "scale=2; (100.00 * $POOL_STAKE_YES) / ($POOL_STAKE_TOTAL - $POOL_STAKE_ABSTAIN)")

  # Generate lists with the committee hashes that are voted yes, no or abstain.
  {
    read -r COMMITTEE_HASH_YES
    read -r COMMITTEE_HASH_ABSTAIN
  } <<< "$(jq -r '
    "\(.committeeVotes | with_entries(select(.value | contains("Yes"))) | keys )",
    "\(.committeeVotes | with_entries(select(.value | contains("Abstain"))) | keys)"
  ' <<< "$ACTION" 2> /dev/null)"

  # Calculate the total power of the yes, no and abstain keys
  {
    read -r COMMITTEE_YES
    read -r COMMITTEE_ABSTAIN
  } <<< "$(jq -r "
    ([ .[] | select(.[0]==${COMMITTEE_HASH_YES}[]) | .[1] ] | add) // 0,
    ([ .[] | select(.[0]==${COMMITTEE_HASH_ABSTAIN}[]) | .[1] ] | add) // 0
  " <<< "$COMMITTEE_DIST" 2> /dev/null)"

  # Calculate the percentage for the committee
  if [ $((COMMITTEE_TOTAL - COMMITTEE_ABSTAIN)) -eq 0 ]; then
    COMMITTEE_PCT="0"
  else
    COMMITTEE_PCT=$(bc <<< "scale=2; (100.00 * $COMMITTEE_YES) / ($COMMITTEE_TOTAL - $COMMITTEE_ABSTAIN)")
  fi
echo
echo

COMMITTEE_ACCEPT_ICON=""
DREP_ACCEPT_ICON=""
DREP_STAKE_THRESHOLD="N/A"
POOL_ACCEPT_ICON=""
POOL_STAKE_THRESHOLD="N/A"
TOTAL_ACCEPT=""
TOTAL_ACCEPT_ICON=""

case "$ACTION_TAG" in
  "InfoAction")
    {
      read -r PREV_ACTION_UTXO
      read -r PREV_ACTION_IDX
    } <<< "$(jq -r '.txId // "-", .govActionIx // "-"' 2> /dev/null <<< "$ACTION_CONTENTS")"

    if [ "${#PREV_ACTION_UTXO}" -gt 1 ]; then
      echo -e "Reference-Action-ID: $GREEN${PREV_ACTION_UTXO}#${PREV_ACTION_IDX}$OFF\n"
    fi

    echo -e "Action-Content:$CYAN Information$OFF"

    DREP_ACCEPT_ICON="N/A"
    POOL_ACCEPT_ICON="N/A"
    TOTAL_ACCEPT="N/A"

    if [ "$(bc <<< "$COMMITTEE_PCT >= $COMMITTEE_THRESHOLD")" -eq 1 ]; then
      COMMITTEE_ACCEPT_ICON="$GREEN_CHECK"
    else
      COMMITTEE_ACCEPT_ICON="$RED_X"
      TOTAL_ACCEPT+="NO"
    fi
  ;;

  "HardForkInitiation")
    {
      read -r PREV_ACTION_UTXO
      read -r PREV_ACTION_IDX
      read -r FORK_MAJOR_VER
      read -r FORK_MINOR_VER
    } <<< "$(jq -r '
      .[0].txId // "-",
      .[0].govActionIx // "-",
      .[1].major // "-",
      .[1].minor // "-"
    ' 2> /dev/null <<< "$ACTION_CONTENTS")"

    if [ ${#PREV_ACTION_UTXO} -gt 1 ]; then
      echo -e "Reference-Action-ID: $GREEN${PREV_ACTION_UTXO}#${PREV_ACTION_IDX}$OFF\n"
    fi

    echo -e "Action-Content: ${CYAN}Do a Hardfork$OFF\n"
    echo -e "Fork to ${GREEN}Protocol-Version$OFF ► $BLUE${FORK_MAJOR_VER}.${FORK_MINOR_VER}$OFF"
    echo

    {
      read -r DREP_STAKE_THRESHOLD
      read -r POOL_STAKE_THRESHOLD
    } <<< "$(jq -r '
      .dRepVotingThresholds.hardForkInitiation // 0,
      .poolVotingThresholds.hardForkInitiation // 0
    ' <<< "$PPARAMS" 2> /dev/null)"

    DREP_STAKE_THRESHOLD=$(bc <<< "scale=2; 100.00 * $DREP_STAKE_THRESHOLD")

    if [ "$PROT_MAJOR_VER" -ge 10 ]; then
      if [ "$(bc <<< "$DREP_PCT >= DREP_STAKE_THRESHOLD")" -eq 1 ]; then
        DREP_ACCEPT_ICON="$GREEN_CHECK"
      else
        DREP_ACCEPT_ICON="$RED_X"
        TOTAL_ACCEPT+="NO"
      fi
    fi

    POOL_STAKE_THRESHOLD=$(bc <<< "scale=2; 100.00 * $POOL_STAKE_THRESHOLD")

    if [ "$(bc <<< "$POOL_PCT >= $POOL_STAKE_THRESHOLD")" -eq 1 ]; then
      POOL_ACCEPT_ICON="$GREEN_CHECK"
    else
      POOL_ACCEPT_ICON="$RED_X"
      TOTAL_ACCEPT+="NO"
    fi

    if [ "$(bc <<< "$COMMITTEE_PCT >= $COMMITTEE_THRESHOLD")" -eq 1 ]; then
      COMMITTEE_ACCEPT_ICON="$GREEN_CHECK"
    else
      COMMITTEE_ACCEPT_ICON="$RED_X"
      TOTAL_ACCEPT+="NO"
    fi
  ;;

  "ParameterChange")
     {
       read -r PREV_ACTION_UTXO
       read -r PREV_ACTION_IDX
       read -r CHANGE_PARAMETERS
     } <<< "$(jq -r '
       .[0].txId // "-",
       .[0].govActionIx // "-",
       "\(.[1])" // "-"
     ' 2> /dev/null <<< "$ACTION_CONTENTS")"

     if [ ${#PREV_ACTION_UTXO} -gt 1 ]; then
       echo -e "Reference-Action-ID: $GREEN${PREV_ACTION_UTXO}#${PREV_ACTION_IDX}$OFF\n"
     fi

     echo -e "Action-Content: ${CYAN}Change protocol parameters$OFF"
     CHANGE_PARAMETERS_RENDER=$(jq -r "to_entries[] | \"Change parameter \(.key) ► \(.value)\"" <<< "$CHANGE_PARAMETERS" 2> /dev/null)
     echo -e "$CHANGE_PARAMETERS_RENDER"
     echo

     DREP_STAKE_THRESHOLD="0"

     case "${CHANGE_PARAMETERS}" in
       # Security group - pools must vote on it
       *"maxBlockBodySize"*|*"maxTxSize"*|*"maxBlockHeaderSize"*|*"maxValueSize"*|*"maxBlockExecutionUnits"*|*"txFeePerByte"*|*"txFeeFixed"*|*"utxoCostPerByte"*|*"govActionDeposit"*|*"minFeeRefScriptCostPerByte"*)
         POOL_STAKE_THRESHOLD=$(jq -r '.poolVotingThresholds.ppSecurityGroup // 0' <<< "${PPARAMS}" 2> /dev/null)
         POOL_STAKE_THRESHOLD=$(bc <<< "scale=2; 100.00 * $POOL_STAKE_THRESHOLD")
         if [ "$(bc <<< "$POOL_PCT >= $POOL_STAKE_THRESHOLD")" -eq 1 ]; then
           POOL_ACCEPT_ICON="$GREEN_CHECK";
         else
           POOL_ACCEPT_ICON="$RED_X"
           TOTAL_ACCEPT+="NO"
         fi
         echo -e "A parameter from the ${GREEN}SECURITY$OFF group is present ► ${BLUE}StakePools must vote$OFF"
         ;;&

       # Network group
       *"maxBlockBodySize"*|*"maxTxSize"*|*"maxBlockHeaderSize"*|*"maxValueSize"*|*"maxTxExecutionUnits"*|*"maxBlockExecutionUnits"*|*"maxCollateralInputs"*)
         DREP_STAKE_THRESHOLD=$(jq -r "[ $DREP_STAKE_THRESHOLD, .dRepVotingThresholds.ppNetworkGroup // 0 ] | max" <<< "$PPARAMS" 2> /dev/null)
         echo -e "A parameter from the ${GREEN}NETWORK$OFF group is present"
         ;;&

       # Economic group
       *"txFeePerByte"*|*"txFeeFixed"*|*"stakeAddressDeposit"*|*"stakePoolDeposit"*|*"monetaryExpansion"*|*"treasuryCut"*|*"minPoolCost"*|*"utxoCostPerByte"*|*"executionUnitPrices"*)
         DREP_STAKE_THRESHOLD=$(jq -r "[ $DREP_STAKE_THRESHOLD, .dRepVotingThresholds.ppEconomicGroup // 0 ] | max" <<< "$PPARAMS" 2> /dev/null)
         echo -e "A parameter from the ${GREEN}ECONOMIC$OFF group is present"
         ;;&

       # Technical group
       *"poolPledgeInfluence"*|*"poolRetireMaxEpoch"*|*"stakePoolTargetNum"*|*"costModels"*|*"collateralPercentage"*)
         DREP_STAKE_THRESHOLD=$(jq -r "[ $DREP_STAKE_THRESHOLD, .dRepVotingThresholds.ppTechnicalGroup // 0 ] | max" <<< "$PPARAMS" 2> /dev/null)
         echo -e "A parameter from the ${GREEN}TECHNICAL$OFF group is present"
         ;;&

       # Governance group
       *"govActionLifetime"*|*"govActionDeposit"*|*"dRepDeposit"*|*"dRepActivity"*|*"committeeMinSize"*|*"committeeMaxTermLength"*|*"VotingThresholds"*)
         DREP_STAKE_THRESHOLD=$(jq -r "[ $DREP_STAKE_THRESHOLD, .dRepVotingThresholds.ppGovGroup // 0 ] | max" <<< "$PPARAMS" 2> /dev/null)
         echo -e "A parameter from the ${GREEN}GOVERNANCE$OFF group is present"
         ;;
     esac

     if [ "$DREP_STAKE_THRESHOLD" == "0" ] || [ "$DREP_STAKE_THRESHOLD" == "" ]; then
       echo -e "${RED}ERROR - Something went wrong finding the dRepPowerThreshold.$OFF"
       exit 1
     fi

     DREP_STAKE_THRESHOLD=$(bc <<< "scale=2; 100.00 * $DREP_STAKE_THRESHOLD")

     if [ "$PROT_MAJOR_VER" -ge 10 ]; then
       if [ "$(bc <<< "$DREP_PCT >= $DREP_STAKE_THRESHOLD")" -eq 1 ]; then
         DREP_ACCEPT_ICON="$GREEN_CHECK"
       else
         DREP_ACCEPT_ICON="$RED_X"
         TOTAL_ACCEPT+="NO"
       fi
     fi

     if [ "$(bc <<< "$COMMITTEE_PCT >= $COMMITTEE_THRESHOLD")" -eq 1 ]; then
       COMMITTEE_ACCEPT_ICON="$GREEN_CHECK"
     else
       COMMITTEE_ACCEPT_ICON="$RED_X"
       TOTAL_ACCEPT+="NO"
     fi
     ;;

  "NewConstitution")
    {
      read -r PREV_ACTION_UTXO
      read -r PREV_ACTION_IDX
      read -r ANCHOR_HASH
      read -r ANCHOR_URL
      read -r SCRIPT_HASH
    } <<< "$(jq -r '
      .[0].txId // "-",
      .[0].govActionIx // "-",
      .[1].anchor.dataHash // "-",
      .[1].anchor.url // "-",
      .[1].script // "-"
    ' 2> /dev/null <<< "$ACTION_CONTENTS")"

    if [ ${#PREV_ACTION_UTXO} -gt 1 ]; then
      echo -e "Reference-Action-ID: $GREEN${PREV_ACTION_UTXO}#$PREV_ACTION_IDX$OFF\n"
    fi

    echo -e "Action-Content: ${CYAN}Change to a new Constitution$OFF\n"
    echo -e "Set new ${GREEN}Constitution-URL$OFF ► $BLUE$ANCHOR_URL$OFF"
    echo -e "Set new ${GREEN}Constitution-Hash$OFF ► $BLUE$ANCHOR_HASH$OFF"
    echo -e "Set new ${GREEN}Guardrails-Script-Hash$OFF ► $BLUE$SCRIPT_HASH$OFF"
    echo

    # Calculate acceptance: Get the right threshold, make it a nice percentage number, check if threshold is reached
    DREP_STAKE_THRESHOLD=$(jq -r '.dRepVotingThresholds.updateToConstitution // 0' <<< "$PPARAMS" 2> /dev/null)
    DREP_STAKE_THRESHOLD=$(bc <<< "scale=2; 100.00 * $DREP_STAKE_THRESHOLD")

    if [ "$(bc <<< "$DREP_PCT >= $DREP_STAKE_THRESHOLD")" -eq 1 ]; then
      DREP_ACCEPT_ICON="$GREEN_CHECK"
    else
      DREP_ACCEPT_ICON="$RED_X"
      TOTAL_ACCEPT+="NO"
    fi

    POOL_ACCEPT_ICON=""

    if [ "$(bc <<< "$COMMITTEE_PCT >= $COMMITTEE_THRESHOLD")" -eq 1 ]; then
      COMMITTEE_ACCEPT_ICON="$GREEN_CHECK"
    else
      COMMITTEE_ACCEPT_ICON="$RED_X"
      TOTAL_ACCEPT+="NO"
    fi
    ;;

  "UpdateCommittee")
     {
       read -r PREV_ACTION_UTXO
       read -r PREV_ACTION_IDX
       read -r COMMITTEE_KEY_HASHES_REMOVE
       read -r COMMITTEE_KEY_HASHES_ADD
       read -r COMMITTEE_THRESHOLD
     } <<< "$(jq -r '
       .[0].txId // "-",
       .[0].govActionIx // "-",
       "\(.[1])" // "[]",
       "\(.[2])" // "[]",
       "\(.[3])" // "-"
     ' 2> /dev/null <<< "$ACTION_CONTENTS")"

     if [ ${#PREV_ACTION_UTXO} -gt 1 ]; then
       echo -e "Reference-Action-ID: $GREEN${PREV_ACTION_UTXO}#${PREV_ACTION_IDX}$OFF\n"
     fi

     COMMITTEE_KEY_HASHES_ADD=$(jq -r "keys" <<< "$COMMITTEE_KEY_HASHES_ADD" 2> /dev/null)
     COMMITTEE_KEY_HASHES_REMOVE=$(jq -r "[.[].keyHash]" <<< "$COMMITTEE_KEY_HASHES_REMOVE" 2> /dev/null)
     COMMITTEE_THRESHOLD_TYPE=$(jq -r "type" <<< "$COMMITTEE_THRESHOLD" 2> /dev/null)

     echo -ne "Action-Content: ${CYAN}Threshold -> "

     case "$COMMITTEE_THRESHOLD_TYPE" in
       "object")
         {
           read -r NUMERATOR
           read -r DENOMINATOR
         } <<< "$(jq -r '.numerator // "-", .denominator // "-"' <<< "$COMMITTEE_THRESHOLD")"
         echo -e "Approval of a governance measure requires $NUMERATOR out of $DENOMINATOR ($(bc <<< "scale=0; ($NUMERATOR * 100 / $DENOMINATOR) / 1")%) of the votes of committee members.$OFF\n"
         ;;

       "number")
         echo -e "Approval of a governance measure requires $(bc <<< "scale=0; ($COMMITTEE_THRESHOLD * 100) / 1")% of the votes of committee members.$OFF\n"
         ;;
     esac

     ADD_HASHES_RENDER=$(jq -r "
       .[2] // {}
         | to_entries[]
         | \"Adding \(.key)-\(.value)\"
         | split(\"-\") | \"\(.[0]) ► \(.[1]) (max term epoch \(.[2]))\"
     " <<< "$ACTION_CONTENTS" 2> /dev/null)

     REM_HASHES_RENDER=$(jq -r "
       .[1][] // []
         | to_entries[]
         | \"Remove \(.key) ◄ \(.value)\"
     " <<< "$ACTION_CONTENTS" 2> /dev/null)

     echo -e "$ADD_HASHES_RENDER"
     echo -e "$REM_HASHES_RENDER"

     {
       read -r DREP_STAKE_THRESHOLD
       read -r POOL_STAKE_THRESHOLD
     } <<< "$(jq -r '.dRepVotingThresholds.committeeNormal // 0, .poolVotingThresholds.committeeNormal // 0' <<< "$PPARAMS" 2> /dev/null)"

     DREP_STAKE_THRESHOLD=$(bc <<< "scale=2; 100.00 * $DREP_STAKE_THRESHOLD")

     if [ "$(bc <<< "$DREP_PCT >= $DREP_STAKE_THRESHOLD")" -eq 1 ]; then
       DREP_ACCEPT_ICON="$GREEN_CHECK"
     else
       DREP_ACCEPT_ICON="$RED_X"
       TOTAL_ACCEPT+="NO"
     fi

     POOL_STAKE_THRESHOLD=$(bc <<< "scale=2; 100.00 * $POOL_STAKE_THRESHOLD")

     if [ "$(bc <<< "$POOL_PCT >= $POOL_STAKE_THRESHOLD")" -eq 1 ]; then
       POOL_ACCEPT_ICON="$GREEN_CHECK"
     else
       POOL_ACCEPT_ICON="$RED_X"
       TOTAL_ACCEPT+="NO"
     fi

     COMMITTEE_ACCEPT_ICON="";
     ;;

  "NoConfidence")
     {
       read -r PREV_ACTION_UTXO
       read -r PREV_ACTION_IDX
     } <<< "$(jq -r '.txId // "-", .govActionIx // "-"' 2> /dev/null <<< "$ACTION_CONTENTS")"

     if [ ${#PREV_ACTION_UTXO} -gt 1 ]; then
       echo -e "Reference-Action-ID: ${CYAN}${PREV_ACTION_UTXO}#${PREV_ACTION_IDX}$OFF\n"
     fi

     echo -e "Action-Content: ${RED}No Confidence in the Committee$OFF"

     {
       read -r DREP_STAKE_THRESHOLD
       read -r POOL_STAKE_THRESHOLD
     } <<< "$(jq -r '.dRepVotingThresholds.committeeNoConfidence // 0, .poolVotingThresholds.committeeNoConfidence // 0' <<< "$PPARAMS" 2> /dev/null)"

     DREP_STAKE_THRESHOLD=$(bc <<< "scale=2; 100.00 * $DREP_STAKE_THRESHOLD")

     if [ "$(bc <<< "$DREP_PCT >= $DREP_STAKE_THRESHOLD")" -eq 1 ]; then
       DREP_ACCEPT_ICON="$GREEN_CHECK"
     else
       DREP_ACCEPT_ICON="$RED_X"
       TOTAL_ACCEPT+="NO"
     fi

     POOL_STAKE_THRESHOLD=$(bc <<< "scale=2; 100.00 * $POOL_STAKE_THRESHOLD")

     if [ "$(bc <<< "$POOL_PCT >= $POOL_STAKE_THRESHOLD")" -eq 1 ]; then
       POOL_ACCEPT_ICON="$GREEN_CHECK"
     else
       POOL_ACCEPT_ICON="$RED_X"
       TOTAL_ACCEPT+="NO"
     fi

     COMMITTEE_ACCEPT_ICON=""
     ;;

  "TreasuryWithdrawals")
    {
      read -r WITHDRAWALS_AMOUNT
      read -r WITHDRAWALS_KEY_TYPE
      read -r WITHDRAWALS_HASH
      read -r WITHDRAWALS_NETWORK
    } <<< "$(jq -r '.[0][0][1] // "0", (.[0][0][0].credential|keys[0]) // "-", (.[0][0][0].credential|flatten[0]) // "-", .[0][0][0].network // "-"' 2> /dev/null <<< "$ACTION_CONTENTS")"

    echo -e "\e[0mAction-Content:\e[36m Withdrawal funds from the treasury\n\e[0m"

    case "${WITHDRAWALS_NETWORK,,}${WITHDRAWALS_KEY_TYPE,,}" in
      *"scripthash")
        echo -e "Withdrawal to ${GREEN}ScriptHash$OFF ► $GREEN$WITHDRAWALS_HASH$OFF"
        ;;

      "mainnet"*)
        WITHDRAWALS_ADDR=$(bech32 "stake" <<< "e1$WITHDRAWALS_HASH" 2> /dev/null)
        # shellcheck disable=SC2181
        if [ "$?" -ne 0 ]; then
          echo -e "\n\e${RED}ERROR - Could not get Withdrawals Stake-Address from KeyHash '$WITHDRAWALS_HASH' !$OFF\n"
          exit 1
        fi
        echo -e "Withdrawal to ${GREEN}StakeAddr$OFF ► $BLUE$WITHDRAWALS_ADDR$OFF"
        ;;

      "testnet"*)
        WITHDRAWALS_ADDR=$(bech32 "stake_test" <<< "e0$WITHDRAWALS_HASH" 2> /dev/null)
        # shellcheck disable=SC2181
        if [ "$?" -ne 0 ]; then
          echo -e "\n\e${RED}ERROR - Could not get Withdrawals Stake-Address from KeyHash '$WITHDRAWALS_HASH' !$OFF\n"
          exit 1
        fi
        echo -e "Withdrawal to ${GREEN}StakeAddr$OFF ► $BLUE$WITHDRAWALS_ADDR$OFF"
        ;;

      "")
        echo -e "Withdrawal ${GREEN}directly$OFF to the ${BLUE}Deposit-Return-Address$OFF\n"
        ;;

      *)
        echo -e "\n${RED}ERROR - Unknown network type $WITHDRAWALS_NETWORK for the Withdrawal KeyHash !$OFF"
        exit 1;
        ;;
    esac

    echo -e "Withdrawal the ${GREEN}Amount$OFF ► $BLUE$WITHDRAWALS_AMOUNT lovelaces$OFF"
    echo

    DREP_STAKE_THRESHOLD=$(jq -r '.dRepVotingThresholds.treasuryWithdrawal // 0' <<< "$PPARAMS" 2> /dev/null)

    DREP_STAKE_THRESHOLD=$(bc <<< "scale=2; 100.00 * $DREP_STAKE_THRESHOLD")

    if [ "$(bc <<< "$DREP_PCT >= $DREP_STAKE_THRESHOLD")" -eq 1 ]; then
      DREP_ACCEPT_ICON="$GREEN_CHECK"
    else
      DREP_ACCEPT_ICON="$RED_X"
      TOTAL_ACCEPT+="NO"
    fi

    POOL_ACCEPT_ICON=""

    if [ "$(bc <<< "$COMMITTEE_PCT >= $COMMITTEE_THRESHOLD")" -eq 1 ]; then
      COMMITTEE_ACCEPT_ICON="$GREEN_CHECK"
    else
      COMMITTEE_ACCEPT_ICON="$RED_X"
      TOTAL_ACCEPT+="NO"
    fi
    ;;
esac

OUTPUT=$(echo -e "Current Votes,Yes,No,Abstain,Threshold,Live-Pct,Accept\n")

if [ "$DREP_ACCEPT_ICON" != "" ]; then
  DREP_SUMMARY="Dreps,$ACTION_DREP_VOTE_YES_COUNT,$ACTION_DREP_VOTE_NO_COUNT,$ACTION_DREP_ABSTAIN_COUNT,$DREP_STAKE_THRESHOLD,$DREP_PCT,$DREP_ACCEPT_ICON"
else
  DREP_SUMMARY="Dreps,-,-,-,-,-,"
fi

if [ "$POOL_ACCEPT_ICON" != "" ]; then
  POOL_SUMMARY="StakePools,$ACTION_POOL_VOTE_YES_COUNT,$ACTION_POOL_VOTE_NO_COUNT,$ACTION_POOL_ABSTAIN_COUNT,$POOL_STAKE_THRESHOLD,$POOL_PCT,$POOL_ACCEPT_ICON"
else
  POOL_SUMMARY="StakePools,-,-,-,-,-,"
fi


if [ "$COMMITTEE_ACCEPT_ICON" != "" ]; then
  COMMITTEE_SUMMARY="Committee,$ACTION_COMMITTEE_VOTE_YES_COUNT,$ACTION_COMMITTEE_VOTE_NO_COUNT,$ACTION_COMMITTEE_ABSTAIN_COUNT,$COMMITTEE_THRESHOLD,$COMMITTEE_PCT,$COMMITTEE_ACCEPT_ICON"
else
  COMMITTEE_SUMMARY="Committee,-,-,-,-,-,"
fi

# shellcheck disable=SC2016
echo -e "$OUTPUT\n$DREP_SUMMARY\n$POOL_SUMMARY\n$COMMITTEE_SUMMARY" | nu --stdin -c '$in | from csv --separator ","'

case "$TOTAL_ACCEPT" in
  *"N/A"*) TOTAL_ACCEPT_ICON="N/A";;
  *"NO"*) TOTAL_ACCEPT_ICON="$RED_X";;
  *) TOTAL_ACCEPT_ICON="$GREEN_CHECK";;
esac

echo -e "Full approval of the proposal: $TOTAL_ACCEPT_ICON"
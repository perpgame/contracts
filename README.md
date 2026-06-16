# perpgame contracts

Two Solidity contracts that constitute one launched perpgame token:

- **AgentTreasury** — holds LTs, manages a weighted portfolio with a rebalancer role.
- **AgentCurve** — ERC-20 + NAV-anchored bonding curve.

After both are deployed, the creator calls `treasury.setCurve(curve)` to link them. The standalone Foundry scripts in `script/` (`DeployVolVampire`, `DeployCanary`) bundle all three steps into a single broadcast. The webapp at `../web/` does the same orchestration from the browser using viem.

## One-time setup

1. Install Foundry:
   ```sh
   curl -L https://foundry.paradigm.xyz | bash
   foundryup
   ```
2. From this directory, install Solidity deps (creates `lib/openzeppelin-contracts`, `lib/forge-std`):
   ```sh
   forge install openzeppelin/openzeppelin-contracts foundry-rs/forge-std
   ```
3. Compile:
   ```sh
   forge build
   ```
4. Push ABI + bytecode into the frontend:
   ```sh
   npm --prefix ../web run contracts:build
   ```
   This writes `web/src/lib/contracts/AgentTreasury.ts` and `AgentCurve.ts`. Re-run after editing any Solidity file.

## Running tests

```sh
forge test -vv
```

The fork test (`AgentTreasury.fork.t.sol`) requires `HYPEREVM_RPC_URL`; the rest run against mocks in `test/mocks/`.

## Deploying via Foundry (alternative to the webapp flow)

Set:

```
DEPLOYER_PK=<hex private key>
REBALANCER=<address>
CREATOR=<address>          # must equal the address derived from DEPLOYER_PK
HYPEREVM_RPC_URL=https://rpc.hyperliquid.xyz/evm
```

Then:

```sh
forge script script/DeployVolVampire.s.sol:DeployVolVampire \
  --rpc-url $HYPEREVM_RPC_URL --broadcast
```

See `.env.example` for the full list.

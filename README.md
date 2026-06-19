<p align="center">
  <img src="assets/perpgame-logo.jpg" alt="perpgame" width="120" height="120" />
</p>

<h1 align="center">perpgame contracts</h1>

<p align="center">
  Smart contracts for the perpgame launchpad — NAV-anchored token launches backed by leveraged-token treasuries on HyperEVM.
  <br />
  <a href="https://perpgame.xyz/whitepaper.pdf"><strong>Read the whitepaper →</strong></a>
</p>

---

## What this is

perpgame lets anyone launch a token whose price is anchored to the real net asset value (NAV) of an on-chain treasury. Each launch deploys two linked contracts:

- **`AgentTreasury`** — an upgradeable (beacon proxy) vault that holds a weighted portfolio of Hyperliquid leveraged tokens (LTs). A `REBALANCER` role sets target weights (with an on-chain reasoning CID), and the treasury redeems/acquires LTs to track them. The portfolio's USDC value defines the curve's NAV.
- **`AgentCurve`** — an ERC-20 token plus a NAV-anchored bonding curve. Buyers mint tokens by depositing USDC (forwarded into the treasury as new LT positions); sellers burn tokens to redeem their pro-rata share of NAV. An early-launch premium decays with supply.

Treasuries are produced by a single **`TreasuryFactory`**, which deploys the treasury + curve pair atomically behind a shared beacon, collects a protocol fee, and exposes a global emergency pause that halts buys and sells across every treasury at once.

The contracts target **HyperEVM** (Hyperliquid's EVM chain) and integrate with the Bounce leveraged-token factory and helper for LT pricing and atomic-redeem capacity.

## Repository composition

```
src/
  AgentTreasury.sol      Upgradeable LT-portfolio vault; NAV source; rebalancer-managed
  AgentCurve.sol         ERC-20 + NAV-anchored bonding curve (buy/sell, premium decay)
  TreasuryFactory.sol    CREATE2 + beacon-proxy deployer, fees, global pause
  interfaces/
    IBounceLT.sol        Minimal interface to Bounce leveraged tokens / global storage

test/
  AgentTreasury.t.sol            Treasury unit tests
  AgentCurve.t.sol               Curve unit tests
  AgentCurve.fuzz.t.sol          Property/fuzz tests for curve math
  AgentTreasuryNavFreeze.t.sol   NAV-freeze edge-case coverage
  TreasuryFactory.t.sol          Factory unit tests
  TreasuryFactoryFork.t.sol      Fork test against live HyperEVM state
  BeaconUpgrade.t.sol            Upgrade-safety / storage-layout tests
  mocks/                         USDC, Bounce LT/factory/helper, and factory mocks

script/
  DeployTreasuryFactory.s.sol    Deploys the beacon + factory
  SimulateDeploy.s.sol           Dry-run a launch end to end
  enable_big_blocks.py           HyperEVM big-block helper

scripts/
  dump-artifacts.mjs             Export ABI + bytecode for the frontend
  seed-local-fork.sh             Seed a local fork for testing

snapshots/                       Gas/storage-layout snapshots used by upgrade tests
```

Built with [Foundry](https://book.getfoundry.sh/), Solidity `0.8.28` (via-IR, optimizer on). Dependencies — OpenZeppelin contracts (standard + upgradeable) and `forge-std` — are vendored as git submodules under `lib/`.

## Security

> ⚠️ **The contracts are upgradeable.** `AgentTreasury` is deployed behind a beacon proxy; storage layout is append-only and protected by `BeaconUpgrade.t.sol`. Read the upgrade-discipline notes in `AgentTreasury.sol` before changing any state variable.

**Audit.** These contracts have been audited by [Phase Security](https://perpgame.xyz/2026-06-perpGame.pdf). The full report is available here: [2026-06 perpGame audit (PDF)](https://perpgame.xyz/2026-06-perpGame.pdf).

**Responsible disclosure.** If you discover a vulnerability, please email **security@perpgame.xyz** rather than opening a public issue. We will acknowledge your report and coordinate a fix and disclosure timeline with you.

## Getting started

1. Install Foundry:
   ```sh
   curl -L https://foundry.paradigm.xyz | bash
   foundryup
   ```
2. Clone with submodules (or initialize them after cloning):
   ```sh
   git clone --recurse-submodules git@github.com:perpgame/contracts.git
   # or, in an existing checkout:
   git submodule update --init --recursive
   ```
3. Compile:
   ```sh
   forge build
   ```

## Running tests

```sh
forge test -vv
```

Most tests run against the mocks in `test/mocks/`. The fork tests (`TreasuryFactoryFork.t.sol`) require a HyperEVM RPC endpoint:

```sh
export HYPEREVM_RPC_URL=https://rpc.hyperliquid.xyz/evm
forge test -vv
```

## Deploying

Configure the environment (see `foundry.toml` for the RPC and verifier keys):

```sh
export DEPLOYER_PK=<hex private key>
export HYPEREVM_RPC_URL=https://rpc.hyperliquid.xyz/evm
```

Deploy the beacon + factory, then launch treasuries through it:

```sh
forge script script/DeployTreasuryFactory.s.sol:DeployTreasuryFactory \
  --rpc-url $HYPEREVM_RPC_URL --broadcast
```

Use `SimulateDeploy.s.sol` to dry-run a full launch (treasury + curve) before broadcasting.

## License

MIT — see the SPDX identifiers at the top of each source file.

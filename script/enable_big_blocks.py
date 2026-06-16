"""
Toggle HyperEVM big blocks for the deployer address by submitting an
`evmUserModify` action to the Hyperliquid exchange API.

Usage:
    pip install hyperliquid-python-sdk eth-account
    export DEPLOYER_PK=0xYOUR_PK
    python enable_big_blocks.py on    # use big blocks
    python enable_big_blocks.py off   # back to small blocks

After running with `on`, all EVM txs from the deployer address route to big
blocks (~30M gas limit, ~1 min latency) until you run with `off` again.
"""

import os
import sys

from eth_account import Account
from hyperliquid.exchange import Exchange
from hyperliquid.utils import constants


def main() -> None:
    if len(sys.argv) != 2 or sys.argv[1] not in {"on", "off"}:
        print("usage: python enable_big_blocks.py [on|off]")
        sys.exit(2)

    pk = os.environ.get("DEPLOYER_PK")
    if not pk:
        print("DEPLOYER_PK not set")
        sys.exit(2)

    using_big_blocks = sys.argv[1] == "on"
    wallet = Account.from_key(pk)
    exchange = Exchange(wallet, constants.MAINNET_API_URL)

    print(f"address:        {wallet.address}")
    print(f"usingBigBlocks: {using_big_blocks}")

    result = exchange.use_big_blocks(using_big_blocks)
    print(f"result:         {result}")


if __name__ == "__main__":
    main()

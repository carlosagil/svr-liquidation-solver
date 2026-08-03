# svr-liquidation-solver

A liquidation solver for Aave V3 on Base, built against **Chainlink SVR** (the oracle-extractable-value
recapture system Chainlink acquired from Atlas in January 2026) — a sealed-bid auction mechanism,
not a latency race. Solidity contract + an off-chain Rust client for opportunity scanning and quoting.

## What this demonstrates

- Porting real swap math (constant-product `getAmountOut`, ported from a prior arrival-latency MEV
  bot) into a new execution context with a different risk model.
- A pre-flight staleness check (`_requireSwapStillFavorable`) that reverts cheaply *before* touching
  Aave if on-chain state drifted between when an opportunity was found and when the winning
  transaction lands — auctions here resolve off-chain, so the state at bid time isn't guaranteed to
  still hold at execution time.
- Foundry fork tests against **live Base mainnet state** (real Aave V3 + real BaseSwap pools), not
  mocks — including a full liquidation that ends with real leftover profit in USDC.
- An off-chain Rust client (`solver-client/`) that scans Aave health factors and computes swap
  quotes with the *same* math as the Solidity contract, so an off-chain quote and the on-chain
  pre-flight check never disagree.
- Direct technical engagement with the protocol team: Chainlink Labs DevRel (Frank Kong) answered
  real open questions about auction mechanics — see below.
- **Real on-chain market research before committing any capital** — the actual reason this stayed a
  portfolio project instead of a live deployment (see "Why this didn't go to mainnet").

## Status

Contract compiles, both fork tests pass (`forge test`), off-chain client builds and runs a live
watchlist scan cleanly. The Atlas bid-submission call itself (`solver-client/src/atlas.rs`,
`submit_bid`) is an explicit `unimplemented!()` — deliberately not built out, because the market
research below made it clear there was no real opening to compete for.

## What I learned from Chainlink's own DevRel

Emailed Chainlink Labs' devrel address with concrete implementation questions; got a real reply
covering:

1. **Auction window: 2 seconds.** Tighter than the "just submit a bid, no rush" assumption I
   started with — a solo off-chain client still has to detect, quote, and submit inside that
   window, competing with other searchers doing the same.
2. **Bonded-balance failure mode**: liquidation transactions simply fail in simulation if bonded
   ETH is insufficient — no surprise cost beyond the failed simulation.
3. **Fee mechanics confirmed**: the bid amount itself is what Chainlink takes from the searcher's
   liquidation transaction — no separate revenue share on top.
4. **How to de-risk before bonding capital**: you can monitor `metacall` invocations on the Atlas
   contract on Base to see real winning liquidations — bid sizes, frequency, how contested it
   actually is — before putting any bonded capital at risk.

## Why this didn't go to mainnet

Point 4 above was the actual next step, and I took it before writing another line of solver code:
pulled real on-chain auction results (956 `SolverTxResult` events over ~4.8 days, filtered to
Aave's confirmed SVR integration on Base) and found the auction is already effectively won — one
address captures 93.4% of liquidations by bidding the practical minimum every time, a second
address gets another 5.6%, and only a handful of others ever bid competitively, on rare large
liquidations. A new solo entrant has no realistic edge against that without a very different
approach to bidding strategy or capital.

I'd rather ship working, tested code and make an honest call not to deploy it than deploy
something into a market that's already saturated. The contract and client here are real,
verified, and reusable if the competitive picture ever changes.

## Build

Solidity (dependencies via Foundry, not vendored in this repo):

```shell
forge install foundry-rs/forge-std
forge install FastLane-Labs/atlas
forge build
forge test
```

Set `BASE_RPC_URL` in a `.env` file (see `.env.example`) before running tests — they fork live
Base mainnet state.

Rust:

```shell
cd solver-client
cargo build
RUST_LOG=info WATCHLIST=0x...,0x... cargo run
```

## Layout

- `src/LiquidationSolver.sol` — the on-chain solver contract, inherits Atlas's `SolverBase`.
- `test/LiquidationSolver.t.sol` — fork tests against real Base mainnet state.
- `solver-client/` — off-chain Rust client (Aave health-factor scanning, swap quoting, bid
  submission scaffold).

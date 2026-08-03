use alloy_primitives::{Address, U256};

/// Mirrors `LiquidationSolver.LiquidationParams` — kept in sync manually since this crate
/// doesn't generate bindings from the Solidity source (no build-time artifact dependency yet).
#[derive(Debug, Clone)]
pub struct LiquidationParams {
    pub collateral_asset: Address,
    pub debt_asset: Address,
    pub user: Address,
    pub debt_to_cover: U256,
    pub swap_pool: Address,
    pub min_swap_amount_out: U256,
    pub expected_seize_amount: U256,
}

/// Builds the `solverOpData` Atlas expects and submits the bid into the SVR auction.
///
/// Deliberately unimplemented — this is exactly the piece blocked on devrel@smartcontract.com's
/// reply (see ../README.md "Open questions"):
/// - the real `bidToken` the Aave SVR auction expects (assumed WETH/native, not verified)
/// - the exact `solverOpData` encoding for this DAppControl (our `liquidate()` signature is a
///   best guess, not copied from a real Aave-SVR integration example)
/// - the auction window duration and how/where to actually submit a bid (no endpoint confirmed)
///
/// Everything upstream of this call (position discovery, health factor checks, swap quoting) is
/// real and runnable today — this is the one seam that has to wait.
pub async fn submit_bid(_params: LiquidationParams) -> eyre::Result<()> {
    unimplemented!(
        "blocked on devrel@smartcontract.com reply — see README.md Open questions before wiring this up"
    )
}

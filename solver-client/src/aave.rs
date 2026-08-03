use alloy_primitives::{Address, U256};
use alloy_provider::Provider;
use alloy_rpc_types::{TransactionInput, TransactionRequest};
use alloy_sol_types::{sol, SolCall};

sol! {
    function getUserAccountData(address user) external view returns (
        uint256 totalCollateralBase,
        uint256 totalDebtBase,
        uint256 availableBorrowsBase,
        uint256 currentLiquidationThreshold,
        uint256 ltv,
        uint256 healthFactor
    );
}

/// 1e18 in Aave's health factor scale — below this, a position is liquidatable.
/// Same threshold `LiquidationSolverTest` asserts against (`hfAfter < 0.95e18` in the crash test,
/// `hfBefore > 1e18` before it).
pub const HEALTH_FACTOR_ONE: U256 = U256::from_limbs([1_000_000_000_000_000_000, 0, 0, 0]);

#[derive(Debug, Clone)]
pub struct AccountData {
    pub user: Address,
    pub total_collateral_base: U256,
    pub total_debt_base: U256,
    pub health_factor: U256,
}

impl AccountData {
    pub fn is_liquidatable(&self) -> bool {
        self.total_debt_base > U256::ZERO && self.health_factor < HEALTH_FACTOR_ONE
    }
}

/// Fetches a single user's Aave account data via `getUserAccountData` — same call
/// `IAavePoolTest.getUserAccountData` makes in the fork tests, just off-chain here.
pub async fn fetch_account_data(
    provider: &impl Provider,
    aave_pool: Address,
    user: Address,
) -> eyre::Result<AccountData> {
    let call = getUserAccountDataCall { user };
    let tx = TransactionRequest::default()
        .to(aave_pool)
        .input(TransactionInput::new(call.abi_encode().into()));

    let raw = provider.call(&tx).await?;
    let decoded = getUserAccountDataCall::abi_decode_returns(&raw, true)?;

    Ok(AccountData {
        user,
        total_collateral_base: decoded.totalCollateralBase,
        total_debt_base: decoded.totalDebtBase,
        health_factor: decoded.healthFactor,
    })
}

use alloy_primitives::{Address, U256};
use alloy_provider::Provider;
use alloy_rpc_types::{TransactionInput, TransactionRequest};
use alloy_sol_types::{sol, SolCall};

sol! {
    function token0() external view returns (address);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
}

/// Standard Uniswap V2 constant-product output formula (0.3% fee) — ported verbatim from
/// `LiquidationSolver._getAmountOut` so the off-chain quote and the on-chain pre-flight check
/// (`_requireSwapStillFavorable`) agree on the same math.
pub fn get_amount_out(amount_in: U256, reserve_in: U256, reserve_out: U256) -> U256 {
    let amount_in_with_fee = amount_in * U256::from(997);
    let numerator = amount_in_with_fee * reserve_out;
    let denominator = reserve_in * U256::from(1000) + amount_in_with_fee;
    numerator / denominator
}

async fn call_view<C: SolCall>(provider: &impl Provider, to: Address, call: C) -> eyre::Result<C::Return> {
    let tx = TransactionRequest::default().to(to).input(TransactionInput::new(call.abi_encode().into()));
    let raw = provider.call(&tx).await?;
    Ok(C::abi_decode_returns(&raw, true)?)
}

/// Fetches `pool`'s live reserves and returns `(reserve_in, reserve_out)` ordered for a swap
/// starting from `token_in` — same token0()/getReserves() pair `_requireSwapStillFavorable` and
/// the fork test's `_quoteRealSwapFloor` read on-chain.
pub async fn fetch_ordered_reserves(
    provider: &impl Provider,
    pool: Address,
    token_in: Address,
) -> eyre::Result<(U256, U256)> {
    let token0 = call_view(provider, pool, token0Call {}).await?._0;
    let reserves = call_view(provider, pool, getReservesCall {}).await?;

    let zero_for_one = token_in == token0;
    let (reserve0, reserve1) = (U256::from(reserves.reserve0), U256::from(reserves.reserve1));
    Ok(if zero_for_one { (reserve0, reserve1) } else { (reserve1, reserve0) })
}

/// Quotes `amount_in` through `pool` and applies a slippage tolerance to derive the floor to pass
/// as `minSwapAmountOut` — mirrors the fork test's `_quoteRealSwapFloor` exactly, just off-chain.
pub async fn quote_swap_floor(
    provider: &impl Provider,
    pool: Address,
    token_in: Address,
    amount_in: U256,
    slippage_bps: U256,
) -> eyre::Result<U256> {
    let (reserve_in, reserve_out) = fetch_ordered_reserves(provider, pool, token_in).await?;
    let full_quote = get_amount_out(amount_in, reserve_in, reserve_out);
    Ok(full_quote * (U256::from(10_000) - slippage_bps) / U256::from(10_000))
}

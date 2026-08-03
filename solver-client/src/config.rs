use alloy_primitives::Address;
use std::str::FromStr;

/// Aave V3 Pool proxy on Base Mainnet — same address as `LiquidationSolver.sol`'s `AAVE_POOL`.
pub const AAVE_POOL: Address = alloy_primitives::address!("A238Dd80C259a72e81d7e4664a9801593F98d1c5");

/// BaseScan-labeled "Aave: Oracle V3" — same address the fork tests use.
pub const AAVE_ORACLE: Address = alloy_primitives::address!("2Cc0Fc26eD4563A5ce5e8bdcfe1A2878676Ae156");

pub struct Config {
    pub http_rpc_url: String,
    /// Borrowers this scaffold checks the health factor of. Real Aave-wide discovery (every
    /// address with an open position) needs either a subgraph or backfilling Borrow/Supply
    /// events across the pool's history — deliberately deferred until the auction integration
    /// itself is unblocked (see ../README.md open questions); a static watchlist is enough to
    /// prove the discovery -> quote pipeline end to end.
    pub watchlist: Vec<Address>,
}

impl Config {
    pub fn from_env() -> eyre::Result<Self> {
        let http_rpc_url = std::env::var("HTTP_RPC_URL")
            .unwrap_or_else(|_| "https://mainnet.base.org".to_string());

        let watchlist = std::env::var("WATCHLIST")
            .unwrap_or_default()
            .split(',')
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .map(Address::from_str)
            .collect::<Result<Vec<_>, _>>()
            .map_err(|e| eyre::eyre!("invalid address in WATCHLIST: {e}"))?;

        Ok(Self { http_rpc_url, watchlist })
    }
}

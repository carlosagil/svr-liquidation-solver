mod aave;
mod atlas;
mod config;
mod quote;

use alloy_provider::ProviderBuilder;
use config::Config;
use tracing::{info, warn};

/// Off-chain solver client for `svr-liquidator` — scaffold only, see ../README.md.
///
/// What's real: Aave health-factor scanning (`aave.rs`) and Uniswap V2-style swap quoting
/// (`quote.rs`), both ported from the same math `LiquidationSolver.sol` and its fork tests use
/// on-chain, so a quote computed here will agree with the contract's own pre-flight check.
///
/// What's not: `atlas::submit_bid` — the SVR auction submission itself, blocked on
/// devrel@smartcontract.com confirming the bid encoding. Discovering a liquidatable position
/// here doesn't yet do anything with it beyond logging.
#[tokio::main]
async fn main() -> eyre::Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::from_default_env())
        .init();

    let config = Config::from_env()?;
    info!(rpc = %config.http_rpc_url, watchlist_size = config.watchlist.len(), "starting solver-client scaffold");

    if config.watchlist.is_empty() {
        warn!("WATCHLIST is empty — set it to a comma-separated list of borrower addresses to scan. \
               Aave-wide discovery (every open position, not just a watchlist) isn't built yet.");
    }

    let url = config.http_rpc_url.parse()?;
    let provider = ProviderBuilder::new().on_http(url);

    for &user in &config.watchlist {
        match aave::fetch_account_data(&provider, config::AAVE_POOL, user).await {
            Ok(account) if account.is_liquidatable() => {
                info!(
                    user = %user,
                    health_factor = %account.health_factor,
                    total_debt_base = %account.total_debt_base,
                    "LIQUIDATABLE position found — swap quoting + bid submission not wired up yet"
                );
            }
            Ok(account) => {
                info!(user = %user, health_factor = %account.health_factor, "healthy");
            }
            Err(e) => {
                warn!(user = %user, error = %e, "failed to fetch account data");
            }
        }
    }

    Ok(())
}

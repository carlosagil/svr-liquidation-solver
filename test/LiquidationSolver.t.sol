// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { LiquidationSolver } from "../src/LiquidationSolver.sol";

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

interface IUniswapV2Pool {
    function token0() external view returns (address);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
}

interface IAavePoolTest {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function borrow(address asset, uint256 amount, uint256 interestRateMode, uint16 referralCode, address onBehalfOf)
        external;
    function getUserAccountData(address user)
        external
        view
        returns (
            uint256 totalCollateralBase,
            uint256 totalDebtBase,
            uint256 availableBorrowsBase,
            uint256 currentLiquidationThreshold,
            uint256 ltv,
            uint256 healthFactor
        );
}

interface IAaveOracle {
    function getAssetPrice(address asset) external view returns (uint256);
    function BASE_CURRENCY_UNIT() external view returns (uint256);
}

/// @title LiquidationSolver fork tests against real Aave V3 + BaseSwap contracts on Base
/// @notice Real historical liquidations were investigated first (tx 0x4bd7f59b9d5dc23...,
///         see [[Dev Logs/2026-07-30 - SVR Liquidation Solver — Scaffolding and Devrel Outreach]])
///         but turned out unreplayable without a paid archive-tracing RPC: the borrower's real
///         health factor was 1.0015 (NOT liquidatable) one block before the real liquidation,
///         and whatever pushed it under 1 happened *inside* the winning bot's own transaction
///         (33 preceding txs in-block, `debug_traceTransaction` needed to see it — Alchemy free
///         tier blocks that call). Rather than guess at reproducing an opaque bot's internal
///         steps, these tests build a genuinely undercollateralized position ourselves — real
///         Aave V3 Pool, real BaseSwap liquidity, real reserve config/liquidation bonus (all
///         fetched on-chain, not guessed) — and force it liquidatable via a mocked oracle price
///         drop, the standard way to test liquidation paths without needing a live crash.
contract LiquidationSolverTest is Test {
    address constant AAVE_POOL = 0xA238Dd80C259a72e81d7e4664a9801593F98d1c5;
    address constant AAVE_ORACLE = 0x2Cc0Fc26eD4563A5ce5e8bdcfe1A2878676Ae156; // BaseScan-labeled "Aave: Oracle V3"
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    /// @dev Real BaseSwap WETH/USDC pool, confirmed via BaseSwap factory's own getPair() —
    ///      not guessed. token0() == WETH.
    address constant SWAP_POOL = 0xab067c01C7F5734da168C699Ae9d23a4512c9FdB;

    /// @dev WETH's real liquidationBonus on Base, fetched from AaveProtocolDataProvider
    ///      (0x0f43731eb8d45a581f4a36dd74f5f358bc90c73a, itself derived on-chain via
    ///      Pool.ADDRESSES_PROVIDER().getPoolDataProvider(), not guessed): 10500 = 105%,
    ///      i.e. a 5% liquidation bonus. Hardcoded here since it's a governance-set constant,
    ///      not something that should silently drift between test runs.
    uint256 constant WETH_LIQUIDATION_BONUS_BPS = 10_500;

    LiquidationSolver solver;
    address borrower = makeAddr("borrower");

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"));
        solver = new LiquidationSolver(WETH, address(0xdead), address(this));
    }

    function _quoteRealSwapFloor(uint256 amountIn, uint256 slippageBps) internal view returns (uint256) {
        (uint112 r0, uint112 r1,) = IUniswapV2Pool(SWAP_POOL).getReserves();
        bool zeroForOne = (WETH == IUniswapV2Pool(SWAP_POOL).token0());
        uint256 reserveIn = zeroForOne ? uint256(r0) : uint256(r1);
        uint256 reserveOut = zeroForOne ? uint256(r1) : uint256(r0);

        uint256 amountInWithFee = amountIn * 997;
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = (reserveIn * 1000) + amountInWithFee;
        uint256 fullQuote = numerator / denominator;

        return fullQuote * (10_000 - slippageBps) / 10_000;
    }

    /// @dev Pre-flight must reject a floor no real swap could hit, and — the important part —
    ///      never touch Aave to find that out. Doesn't need an actual liquidatable position:
    ///      liquidate() checks the swap leg before ever requesting the flash loan.
    function test_liquidate_revertsOnStaleReserves_beforeTouchingAave() public {
        uint256 seizeAmount = 1 ether; // arbitrary but realistic-scale WETH amount
        uint256 impossibleFloor = _quoteRealSwapFloor(seizeAmount, 0) * 2; // unreachable

        LiquidationSolver.LiquidationParams memory p = LiquidationSolver.LiquidationParams({
            collateralAsset: WETH,
            debtAsset: USDC,
            user: borrower,
            debtToCover: 1000e6,
            swapPool: SWAP_POOL,
            minSwapAmountOut: impossibleFloor,
            expectedSeizeAmount: seizeAmount
        });

        vm.prank(address(solver));
        vm.expectRevert("Stale reserves");
        solver.liquidate(p);
    }

    /// @dev Full path against a genuinely undercollateralized real position: supply WETH,
    ///      borrow USDC near max LTV (both real Aave calls), crash the oracle price 22% (real
    ///      liquidation-testing pattern — Aave's own price is mocked, everything downstream —
    ///      health factor calc, liquidation bonus, BaseSwap swap — is real).
    /// @dev Collateral sized at 0.1 WETH — deliberately close to the real historical example's
    ///      scale (0.044556 WETH, see the module-level comment). A first attempt at 5 WETH
    ///      technically liquidated fine, but the seize amount (~4.69 WETH, after the bonus) was
    ///      ~94% of SWAP_POOL's entire ~5 WETH reserve — cratered the price on the way out via
    ///      slippage and failed to repay the flash loan. Not a contract bug: this specific real
    ///      pool just doesn't have the depth for a liquidation that large.
    function test_liquidate_syntheticUndercollateralizedPosition_succeeds() public {
        uint256 wethPrice = IAaveOracle(AAVE_ORACLE).getAssetPrice(WETH); // real price, 8 decimals
        uint256 usdcPrice = IAaveOracle(AAVE_ORACLE).getAssetPrice(USDC);

        uint256 collateralAmount = 0.1 ether;
        deal(WETH, borrower, collateralAmount);

        vm.startPrank(borrower);
        IERC20(WETH).approve(AAVE_POOL, collateralAmount);
        IAavePoolTest(AAVE_POOL).supply(WETH, collateralAmount, borrower, 0);

        // Borrow at 70% LTV (real WETH LTV is 80% — leaving room so this borrow itself doesn't
        // immediately fail Aave's own post-borrow health check).
        uint256 collateralValueBase = collateralAmount * wethPrice / 1e18;
        uint256 borrowValueBase = collateralValueBase * 70 / 100;
        uint256 debtToCover = borrowValueBase * 1e6 / usdcPrice; // USDC has 6 decimals
        IAavePoolTest(AAVE_POOL).borrow(USDC, debtToCover, 2, 0, borrower); // 2 = variable rate
        vm.stopPrank();

        (,,,,, uint256 hfBefore) = IAavePoolTest(AAVE_POOL).getUserAccountData(borrower);
        assertGt(hfBefore, 1e18, "sanity: should be healthy before the price crash");

        // Crash WETH's oracle price 22% — real liquidation-testing pattern, not a live event.
        // Every calculation downstream of this (health factor, liquidation bonus, the swap) is
        // real Aave/BaseSwap logic against real on-chain state. Sized to land inside the narrow
        // window between "liquidatable" and "collateral no longer covers the debt at all" — a
        // 40% crash was tried first and overshot past insolvency entirely: Aave capped the
        // seizure at all remaining collateral and booked the rest as bad debt (`DeficitCreated`
        // event), which is a real Aave mechanism but a different scenario than a normal
        // liquidation-bonus liquidation, and produced a real seize amount smaller than this
        // contract's `expectedSeizeAmount` — hence the original "Insufficient output amount".
        uint256 crashedPrice = wethPrice * 78 / 100;
        vm.mockCall(
            AAVE_ORACLE, abi.encodeWithSelector(IAaveOracle.getAssetPrice.selector, WETH), abi.encode(crashedPrice)
        );

        (,,,,, uint256 hfAfter) = IAavePoolTest(AAVE_POOL).getUserAccountData(borrower);
        assertLt(hfAfter, 0.95e18, "should be under the close-factor threshold (100% liquidatable)");
        assertGt(hfAfter, 0.5e18, "sanity: shouldn't be so far under water that this is a bad-debt scenario");

        // Aave's own formula (LiquidationLogic._calculateAvailableCollateralToLiquidate):
        // seizedCollateral = debtToCover-in-base * liquidationBonus / collateralPrice-in-base,
        // decimal-adjusted. Same computation an off-chain solver client would do, just run here.
        uint256 debtValueBase = debtToCover * usdcPrice / 1e6;
        uint256 bonusedValueBase = debtValueBase * WETH_LIQUIDATION_BONUS_BPS / 10_000;
        uint256 expectedSeizeAmount = bonusedValueBase * 1e18 / crashedPrice;

        uint256 minSwapAmountOut = _quoteRealSwapFloor(expectedSeizeAmount, 500); // 5% slippage tolerance

        // A tiny buffer (0.1%) on the requested debtToCover — real variable-debt interest
        // accrues every second, so the exact debt at quote time is already stale by execution
        // time. Passing the bare unbuffered amount reverted with Aave's `MustNotLeaveDust()`:
        // it fully closes the position when asked to cover >= the real debt, but requires the
        // liquidator to either close it all or leave a meaningful remainder — not a rounding
        // sliver. Aave caps the *actual* pull to the real debt regardless of this ceiling, so
        // `expectedSeizeAmount` above (computed from the unbuffered amount) still matches what
        // gets bonused; this only affects the flash-loan/liquidationCall request ceiling. A real
        // off-chain solver client should do the same for the same reason.
        uint256 debtToCoverRequested = debtToCover * 1001 / 1000;

        LiquidationSolver.LiquidationParams memory p = LiquidationSolver.LiquidationParams({
            collateralAsset: WETH,
            debtAsset: USDC,
            user: borrower,
            debtToCover: debtToCoverRequested,
            swapPool: SWAP_POOL,
            minSwapAmountOut: minSwapAmountOut,
            expectedSeizeAmount: expectedSeizeAmount
        });

        uint256 usdcBefore = IERC20(USDC).balanceOf(address(solver));

        vm.prank(address(solver));
        solver.liquidate(p);

        uint256 usdcAfter = IERC20(USDC).balanceOf(address(solver));
        assertGt(usdcAfter, usdcBefore, "expected leftover USDC profit after repaying the flash loan");
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { SolverBase } from "../lib/atlas/src/contracts/solver/SolverBase.sol";

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IUniswapV2Pool {
    function token0() external view returns (address);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function swap(uint amount0Out, uint amount1Out, address to, bytes calldata data) external;
}

/// @notice Aave V3 Pool on Base Mainnet
interface IAavePool {
    function flashLoanSimple(
        address receiverAddress,
        address asset,
        uint256 amount,
        bytes calldata params,
        uint16 referralCode
    ) external;

    /// @param receiveAToken false = liquidator receives the underlying collateral token, not the aToken
    function liquidationCall(
        address collateralAsset,
        address debtAsset,
        address user,
        uint256 debtToCover,
        bool receiveAToken
    ) external;
}

/// @title LiquidationSolver — Atlas/Chainlink SVR solver for Aave V3 Base liquidations
/// @notice Separate project from [[MevExecutor]] (contracts/) — different auction mechanism
///         (bid-based via Atlas, not arrival-latency). See svr-liquidator/README.md for the
///         open questions still pending confirmation from Chainlink devrel before mainnet use.
/// @dev Entry point is `atlasSolverCall` (inherited from SolverBase), which Atlas calls after
///      winning the bid auction. That does a self-call into `solverOpData` — we point it at
///      `liquidate()` below. Flash loan pattern is the same one proven in MevExecutor.sol.
contract LiquidationSolver is SolverBase {
    /// @dev Aave V3 Pool proxy on Base Mainnet — same address used by MevExecutor
    address private constant AAVE_POOL = 0xA238Dd80C259a72e81d7e4664a9801593F98d1c5;

    struct LiquidationParams {
        address collateralAsset;
        address debtAsset;
        address user;
        uint256 debtToCover;
        // Off-chain-computed swap step to convert seized collateral back to debtAsset
        // (or to bidToken, once we confirm which currency the auction expects — see README).
        // Mirrors MevExecutor's off-chain-computed-path pattern: solver client picks the pool,
        // contract only re-checks it's still favorable before touching Aave.
        address swapPool;
        uint256 minSwapAmountOut;
        // Off-chain-computed collateral amount the solver client expects to seize (function of
        // debtToCover, this reserve's liquidation bonus, and the oracle price at quote time —
        // none of which this contract re-derives, same as MevExecutor never re-derives its
        // off-chain amountsOut from scratch, only checks them against live DEX reserves).
        uint256 expectedSeizeAmount;
    }

    constructor(address weth, address atlas, address owner) SolverBase(weth, atlas, owner) { }

    /// @notice Called via the self-call inside `atlasSolverCall` (see SolverBase.atlasSolverCall).
    /// @dev Only callable by this contract itself — Atlas's low-level call target.
    function liquidate(LiquidationParams calldata p) external {
        require(msg.sender == address(this), "Only self");

        // Cheap pre-flight before we ever touch Aave, same reasoning as MevExecutor's
        // _requireReservesStillFavorable: the off-chain solver quoted swapPool's reserves at
        // opportunity-detection time, but the auction resolves off-chain — by the time this
        // call lands on-chain, another swap could have moved that pool's reserves against us.
        // Re-deriving the expected output here costs one getReserves() call (~2-5k gas) and
        // reverts before the flash loan + liquidationCall (both real gas) ever run.
        _requireSwapStillFavorable(p.collateralAsset, p.swapPool, p.expectedSeizeAmount, p.minSwapAmountOut);

        bytes memory params = abi.encode(p);

        // Borrow exactly the debt amount we're covering — zero capital, same as MevExecutor.
        IAavePool(AAVE_POOL).flashLoanSimple(address(this), p.debtAsset, p.debtToCover, params, 0);
    }

    /// @notice Aave V3 flash loan callback — performs the liquidation and repays Aave.
    function executeOperation(
        address asset,
        uint256 amount,
        uint256 premium,
        address initiator,
        bytes calldata params
    ) external returns (bool) {
        require(msg.sender == AAVE_POOL, "Only Aave");
        require(initiator == address(this), "Only self");

        LiquidationParams memory p = abi.decode(params, (LiquidationParams));

        // Repay the target user's debt, receive their collateral at the protocol's liquidation
        // bonus (~5-10% on Base per observed real liquidations, see dev log).
        IERC20(asset).approve(AAVE_POOL, amount);
        IAavePool(AAVE_POOL).liquidationCall(p.collateralAsset, p.debtAsset, p.user, amount, false);

        // Swap seized collateral back to the debt asset to repay the flash loan + premium.
        // TODO(pending devrel confirmation): if the SVR auction's bidToken isn't `debtAsset`,
        // this needs a second swap leg after repayment — left as a stub until confirmed.
        uint256 collateralBalance = IERC20(p.collateralAsset).balanceOf(address(this));
        _swap(p.collateralAsset, p.swapPool, collateralBalance, p.minSwapAmountOut);

        IERC20(p.debtAsset).approve(AAVE_POOL, amount + premium);
        return true;
    }

    /// @dev Standard Uniswap V2 constant-product output formula (0.3% fee) — ported verbatim
    ///      from MevExecutor._getAmountOut. Matches the invariant check inside the real pool's
    ///      swap(), so a pass here means the swap below will not revert with "UniswapV2: K".
    function _getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut) private pure returns (uint256) {
        uint256 amountInWithFee = amountIn * 997;
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = (reserveIn * 1000) + amountInWithFee;
        return numerator / denominator;
    }

    /// @dev Reverts cheaply if swapPool's current on-chain reserves can no longer deliver
    ///      minSwapAmountOut for the off-chain-quoted expectedSeizeAmount — see the comment at
    ///      the call site in `liquidate()`. Same shape as MevExecutor._requireReservesStillFavorable,
    ///      collapsed to a single hop since a liquidation only has one swap leg.
    function _requireSwapStillFavorable(
        address collateralAsset,
        address swapPool,
        uint256 expectedSeizeAmount,
        uint256 minSwapAmountOut
    ) private view {
        address token0 = IUniswapV2Pool(swapPool).token0();
        bool zeroForOne = (collateralAsset == token0);

        (uint112 reserve0, uint112 reserve1, ) = IUniswapV2Pool(swapPool).getReserves();
        uint256 reserveIn = zeroForOne ? uint256(reserve0) : uint256(reserve1);
        uint256 reserveOut = zeroForOne ? uint256(reserve1) : uint256(reserve0);

        require(
            _getAmountOut(expectedSeizeAmount, reserveIn, reserveOut) >= minSwapAmountOut,
            "Stale reserves"
        );
    }

    /// @dev Minimal V2-style pool swap, same shape as MevExecutor's hop execution.
    ///      Pool is picked off-chain by the solver client (same off-chain-path /
    ///      on-chain-just-executes-and-checks-a-floor division of responsibility as the arb
    ///      bot) — amountOut itself is now derived on-chain from live reserves, not passed in,
    ///      so minAmountOut is purely a floor check against reserve drift since the solver
    ///      client last quoted this pool.
    function _swap(address tokenIn, address pool, uint256 amountIn, uint256 minAmountOut) private {
        address token0 = IUniswapV2Pool(pool).token0();
        bool zeroForOne = (tokenIn == token0);

        (uint112 reserve0, uint112 reserve1, ) = IUniswapV2Pool(pool).getReserves();
        uint256 reserveIn = zeroForOne ? uint256(reserve0) : uint256(reserve1);
        uint256 reserveOut = zeroForOne ? uint256(reserve1) : uint256(reserve0);

        uint256 amountOut = _getAmountOut(amountIn, reserveIn, reserveOut);
        require(amountOut >= minAmountOut, "Insufficient output amount");

        require(IERC20(tokenIn).transfer(pool, amountIn), "Transfer failed");

        uint256 out0 = zeroForOne ? 0 : amountOut;
        uint256 out1 = zeroForOne ? amountOut : 0;
        IUniswapV2Pool(pool).swap(out0, out1, address(this), new bytes(0));
    }
}

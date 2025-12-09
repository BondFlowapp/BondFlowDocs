// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

interface INonfungiblePositionManager {
    struct MintParams {
        address token0;
        address token1;
        uint24  fee;
        int24   tickLower;
        int24   tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
    }
    struct IncreaseLiquidityParams {
        uint256 tokenId;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }
    struct DecreaseLiquidityParams {
        uint256 tokenId;
        uint128 liquidity;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }
    struct CollectParams {
        uint256 tokenId;
        address recipient;
        uint128 amount0Max;
        uint128 amount1Max;
    }
    function mint(MintParams calldata params) external payable returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);
    function increaseLiquidity(IncreaseLiquidityParams calldata params) external payable returns (uint128 liquidity, uint256 amount0, uint256 amount1);
    function decreaseLiquidity(DecreaseLiquidityParams calldata params) external payable returns (uint256 amount0, uint256 amount1);
    function collect(CollectParams calldata params) external payable returns (uint256 amount0, uint256 amount1);
    function positions(uint256 tokenId)
        external
        view
        returns (
            uint96 nonce,
            address operator,
            address token0,
            address token1,
            uint24 fee,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        );
    function burn(uint256 tokenId) external payable;
}

interface ISwapRouterV3 {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24  fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }
    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

interface IEngineVault {
    function fundInflowFromVault(uint256 amount) external;
}

interface IBondFlowView {
    function tvl() external view returns (uint256);
    function vaultAllocBps() external view returns (uint16);
}

error ZERO();
error NOT_ENGINE();
error NO_POSITION();
error EXISTS();
error NOT_OPERATOR();

contract PoolBondFlow is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    address public constant WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    address public constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    
    address public constant NPM_ADDRESS   = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;
    address public constant SWAP_ROUTER_A = 0xE592427A0AEce92De3Edee1F18E0157C05861564;
    address public constant SWAP_ROUTER_B = 0xE592427A0AEce92De3Edee1F18E0157C05861564;

    IERC20 public immutable usdcToken = IERC20(USDC);
    IERC20 public immutable wethToken = IERC20(WETH);

    INonfungiblePositionManager public immutable npm      = INonfungiblePositionManager(NPM_ADDRESS);
    ISwapRouterV3                public immutable routerA = ISwapRouterV3(SWAP_ROUTER_A);
    ISwapRouterV3                public immutable routerB = ISwapRouterV3(SWAP_ROUTER_B);

    address public engine;
    address public operator;

    uint256 public positionIdUsdcWethLow;
    uint256 public positionIdUsdcWethHigh;

    uint256 public totalFeesUsdcFromLow;
    uint256 public totalFeesWethFromLow;
    uint256 public totalFeesUsdcFromHigh;
    uint256 public totalFeesWethFromHigh;
    uint256 public totalFeesUsdcExtra;

    uint256 public feesOwedUsdcLow;
    uint256 public feesOwedWethLow;
    uint256 public feesOwedUsdcHigh;
    uint256 public feesOwedWethHigh;
    uint256 public feesOwedUsdcExtra;

    event EngineSet(address indexed engine);
    event OperatorSet(address indexed operator);

    event PositionMintedLow(uint256 indexed tokenId, uint128 liquidity, uint256 usedUsdc, uint256 usedWeth);
    event PositionIncreasedLow(uint256 indexed tokenId, uint128 liquidityAdded, uint256 usedUsdc, uint256 usedWeth);
    event PositionDecreasedLow(uint256 indexed tokenId, uint256 amtUsdc, uint256 amtWeth);
    event PositionFeesCollectedLow(uint256 indexed tokenId, uint256 feesUsdc, uint256 feesWeth);

    event PositionMintedHigh(uint256 indexed tokenId, uint128 liquidity, uint256 usedUsdc, uint256 usedWeth);
    event PositionIncreasedHigh(uint256 indexed tokenId, uint128 liquidityAdded, uint256 usedUsdc, uint256 usedWeth);
    event PositionDecreasedHigh(uint256 indexed tokenId, uint256 amtUsdc, uint256 amtWeth);
    event PositionFeesCollectedHigh(uint256 indexed tokenId, uint256 feesUsdc, uint256 feesWeth);

    event RebalancedToNewLow(uint256 indexed oldTokenId, uint256 indexed newTokenId, uint24 feeNew, int24 tickLowerNew, int24 tickUpperNew);

    event SwappedUsdcWeth(bool usdcToWeth, uint256 amountIn, uint256 amountOut, uint24 feeTier);
    event SwappedWethToUsdc(uint256 amountIn, uint256 amountOut, uint24 feeTier);

    event PulledToEngine(uint256 amountUsdc);
    event FeesOwedUpdated(
        uint256 feesUsdcLow,
        uint256 feesWethLow,
        uint256 feesUsdcHigh,
        uint256 feesWethHigh,
        uint256 feesUsdcExtra
    );
    event FeesPaidToEngine(uint256 amountUsdc);
    event UsdcOnlyFeesAdded(uint256 amountUsdc);

    modifier onlyEngine() {
        if (msg.sender != engine) revert NOT_ENGINE();
        _;
    }

    modifier onlyOperator() {
        if (msg.sender != operator) revert NOT_OPERATOR();
        _;
    }

    modifier onlyOperatorOrOwner() {
        if (msg.sender != operator && msg.sender != owner()) revert NOT_OPERATOR();
        _;
    }

    constructor() Ownable(msg.sender) {}

    function setEngine(address e) external onlyOwner {
        if (e == address(0)) revert ZERO();
        if (engine != address(0)) revert EXISTS();
        engine = e;
        emit EngineSet(e);
    }

    function setOperator(address op) external onlyOwner {
        operator = op;
        emit OperatorSet(op);
    }

    function _approveAll() internal {
        usdcToken.forceApprove(address(npm), type(uint256).max);
        wethToken.forceApprove(address(npm), type(uint256).max);

        usdcToken.forceApprove(address(routerA), type(uint256).max);
        wethToken.forceApprove(address(routerA), type(uint256).max);

        usdcToken.forceApprove(address(routerB), type(uint256).max);
        wethToken.forceApprove(address(routerB), type(uint256).max);
    }

    function _reapprovePerSwap(address token, address spender) internal {
        IERC20(token).forceApprove(spender, 0);
        IERC20(token).forceApprove(spender, type(uint256).max);
    }

    function _swapExactInput(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minOut,
        uint24 fee,
        uint256 deadline
    ) internal returns (uint256 out) {
        _reapprovePerSwap(tokenIn, address(routerA));
        _reapprovePerSwap(tokenIn, address(routerB));

        bool ok = true;

        try routerA.exactInputSingle(
            ISwapRouterV3.ExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                fee: fee,
                recipient: address(this),
                deadline: deadline,
                amountIn: amountIn,
                amountOutMinimum: minOut,
                sqrtPriceLimitX96: 0
            })
        ) returns (uint256 amountOut) {
            out = amountOut;
        } catch {
            ok = false;
        }

        if (!ok) {
            out = routerB.exactInputSingle(
                ISwapRouterV3.ExactInputSingleParams({
                    tokenIn: tokenIn,
                    tokenOut: tokenOut,
                    fee: fee,
                    recipient: address(this),
                    deadline: deadline,
                    amountIn: amountIn,
                    amountOutMinimum: minOut,
                    sqrtPriceLimitX96: 0
                })
            );
        }
    }

    function _swapAllWethToUsdc(uint24 feeTier, uint256 deadline) internal returns (uint256 out) {
        uint256 amountIn = wethToken.balanceOf(address(this));
        if (amountIn == 0) return 0;

        out = _swapExactInput(address(wethToken), address(usdcToken), amountIn, 0, feeTier, deadline);
        emit SwappedWethToUsdc(amountIn, out, feeTier);
    }

    function swapUsdcWeth(
    uint256 amountIn,
    bool usdcToWeth,
    uint256 minOut,
    uint24 feeTier,
    uint256 deadline
) external onlyOperator nonReentrant returns (uint256 out) {
    if (amountIn == 0) revert ZERO();

    address tokenIn  = usdcToWeth ? address(usdcToken) : address(wethToken);
    address tokenOut = usdcToWeth ? address(wethToken) : address(usdcToken);

    out = _swapExactInput(tokenIn, tokenOut, amountIn, minOut, feeTier, deadline);

    emit SwappedUsdcWeth(usdcToWeth, amountIn, out, feeTier);
}


    function _getNpmPosition(uint256 tokenId)
        internal
        view
        returns (
            uint24 fee,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        )
    {
        (
            ,
            ,
            ,
            ,
            uint24 fee_,
            int24 tickLower_,
            int24 tickUpper_,
            uint128 liq_,
            ,
            ,
            uint128 owed0_,
            uint128 owed1_
        ) = npm.positions(tokenId);

        return (fee_, tickLower_, tickUpper_, liq_, owed0_, owed1_);
    }

    function mintPositionLow(
        uint24 fee,
        int24 tickLower,
        int24 tickUpper,
        uint256 amountUsdc,
        uint256 amountWeth,
        uint256 minUsdc,
        uint256 minWeth,
        uint256 deadline
    ) external onlyOperator nonReentrant returns (uint256 tokenId, uint128 liquidity, uint256 usedUsdc, uint256 usedWeth) {
        _approveAll();

        (tokenId, liquidity, usedWeth, usedUsdc) = npm.mint(
            INonfungiblePositionManager.MintParams({
                token0: WETH,
                token1: USDC,
                fee: fee,
                tickLower: tickLower,
                tickUpper: tickUpper,
                amount0Desired: amountWeth,
                amount1Desired: amountUsdc,
                amount0Min: minWeth,
                amount1Min: minUsdc,
                recipient: address(this),
                deadline: deadline
            })
        );

        if (positionIdUsdcWethLow == 0) {
            positionIdUsdcWethLow = tokenId;
        }

        emit PositionMintedLow(tokenId, liquidity, usedUsdc, usedWeth);
    }

    function increaseLow(
        uint256 tokenId,
        uint256 amountUsdc,
        uint256 amountWeth,
        uint256 minUsdc,
        uint256 minWeth,
        uint256 deadline
    ) external onlyOperator nonReentrant returns (uint128 liquidity, uint256 usedUsdc, uint256 usedWeth) {
        if (tokenId == 0) revert NO_POSITION();
        _approveAll();

        (liquidity, usedWeth, usedUsdc) = npm.increaseLiquidity(
            INonfungiblePositionManager.IncreaseLiquidityParams({
                tokenId: tokenId,
                amount0Desired: amountWeth,
                amount1Desired: amountUsdc,
                amount0Min: minWeth,
                amount1Min: minUsdc,
                deadline: deadline
            })
        );

        emit PositionIncreasedLow(tokenId, liquidity, usedUsdc, usedWeth);
    }

    function decreaseAndCollectLow(
        uint256 tokenId,
        uint128 liquidity,
        uint256 minUsdc,
        uint256 minWeth,
        uint256 deadline
    ) external onlyOperator nonReentrant returns (uint256 amtUsdc, uint256 amtWeth, uint256 feesUsdc, uint256 feesWeth) {
        if (tokenId == 0) revert NO_POSITION();

        (amtWeth, amtUsdc) = npm.decreaseLiquidity(
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: tokenId,
                liquidity: liquidity,
                amount0Min: minWeth,
                amount1Min: minUsdc,
                deadline: deadline
            })
        );

        (uint256 feesWethTmp, uint256 feesUsdcTmp) = npm.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: tokenId,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );

        feesUsdc = feesUsdcTmp;
        feesWeth = feesWethTmp;

        totalFeesUsdcFromLow += feesUsdc;
        totalFeesWethFromLow += feesWeth;
        feesOwedUsdcLow += feesUsdc;
        feesOwedWethLow += feesWeth;

        emit PositionDecreasedLow(tokenId, amtUsdc, amtWeth);
        emit PositionFeesCollectedLow(tokenId, feesUsdc, feesWeth);
        emit FeesOwedUpdated(feesOwedUsdcLow, feesOwedWethLow, feesOwedUsdcHigh, feesOwedWethHigh, feesOwedUsdcExtra);
    }

    function collectAllLow(uint256 tokenId) external onlyOperator nonReentrant returns (uint256 feesUsdc, uint256 feesWeth) {
        if (tokenId == 0) revert NO_POSITION();

        (uint256 feesWethTmp, uint256 feesUsdcTmp) = npm.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: tokenId,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );

        feesUsdc = feesUsdcTmp;
        feesWeth = feesWethTmp;

        totalFeesUsdcFromLow += feesUsdc;
        totalFeesWethFromLow += feesWeth;
        feesOwedUsdcLow += feesUsdc;
        feesOwedWethLow += feesWeth;

        emit PositionFeesCollectedLow(tokenId, feesUsdc, feesWeth);
        emit FeesOwedUpdated(feesOwedUsdcLow, feesOwedWethLow, feesOwedUsdcHigh, feesOwedWethHigh, feesOwedUsdcExtra);
    }

    function mintPositionHigh(
        uint24 fee,
        int24 tickLower,
        int24 tickUpper,
        uint256 amountUsdc,
        uint256 amountWeth,
        uint256 minUsdc,
        uint256 minWeth,
        uint256 deadline
    ) external onlyOperator nonReentrant returns (uint256 tokenId, uint128 liquidity, uint256 usedUsdc, uint256 usedWeth) {
        _approveAll();

        (tokenId, liquidity, usedWeth, usedUsdc) = npm.mint(
            INonfungiblePositionManager.MintParams({
                token0: WETH,
                token1: USDC,
                fee: fee,
                tickLower: tickLower,
                tickUpper: tickUpper,
                amount0Desired: amountWeth,
                amount1Desired: amountUsdc,
                amount0Min: minWeth,
                amount1Min: minUsdc,
                recipient: address(this),
                deadline: deadline
            })
        );

        if (positionIdUsdcWethHigh == 0) {
            positionIdUsdcWethHigh = tokenId;
        }

        emit PositionMintedHigh(tokenId, liquidity, usedUsdc, usedWeth);
    }

    function increaseHigh(
        uint256 tokenId,
        uint256 amountUsdc,
        uint256 amountWeth,
        uint256 minUsdc,
        uint256 minWeth,
        uint256 deadline
    ) external onlyOperator nonReentrant returns (uint128 liquidity, uint256 usedUsdc, uint256 usedWeth) {
        if (tokenId == 0) revert NO_POSITION();
        _approveAll();

        (liquidity, usedWeth, usedUsdc) = npm.increaseLiquidity(
            INonfungiblePositionManager.IncreaseLiquidityParams({
                tokenId: tokenId,
                amount0Desired: amountWeth,
                amount1Desired: amountUsdc,
                amount0Min: minWeth,
                amount1Min: minUsdc,
                deadline: deadline
            })
        );

        emit PositionIncreasedHigh(tokenId, liquidity, usedUsdc, usedWeth);
    }

    function decreaseAndCollectHigh(
        uint256 tokenId,
        uint128 liquidity,
        uint256 minUsdc,
        uint256 minWeth,
        uint256 deadline
    ) external onlyOperator nonReentrant returns (uint256 amtUsdc, uint256 amtWeth, uint256 feesUsdc, uint256 feesWeth) {
        if (tokenId == 0) revert NO_POSITION();

        (amtWeth, amtUsdc) = npm.decreaseLiquidity(
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: tokenId,
                liquidity: liquidity,
                amount0Min: minWeth,
                amount1Min: minUsdc,
                deadline: deadline
            })
        );

        (uint256 feesWethTmp, uint256 feesUsdcTmp) = npm.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: tokenId,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );

        feesUsdc = feesUsdcTmp;
        feesWeth = feesWethTmp;

        totalFeesUsdcFromHigh += feesUsdc;
        totalFeesWethFromHigh += feesWeth;
        feesOwedUsdcHigh += feesUsdc;
        feesOwedWethHigh += feesWeth;

        emit PositionDecreasedHigh(tokenId, amtUsdc, amtWeth);
        emit PositionFeesCollectedHigh(tokenId, feesUsdc, feesWeth);
        emit FeesOwedUpdated(feesOwedUsdcLow, feesOwedWethLow, feesOwedUsdcHigh, feesOwedWethHigh, feesOwedUsdcExtra);
    }

    function collectAllHigh(uint256 tokenId) external onlyOperator nonReentrant returns (uint256 feesUsdc, uint256 feesWeth) {
        if (tokenId == 0) revert NO_POSITION();

        (uint256 feesWethTmp, uint256 feesUsdcTmp) = npm.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: tokenId,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );

        feesUsdc = feesUsdcTmp;
        feesWeth = feesWethTmp;

        totalFeesUsdcFromHigh += feesUsdc;
        totalFeesWethFromHigh += feesWeth;
        feesOwedUsdcHigh += feesUsdc;
        feesOwedWethHigh += feesWeth;

        emit PositionFeesCollectedHigh(tokenId, feesUsdc, feesWeth);
        emit FeesOwedUpdated(feesOwedUsdcLow, feesOwedWethLow, feesOwedUsdcHigh, feesOwedWethHigh, feesOwedUsdcExtra);
    }

    struct RebalanceParamsLow {
        uint128 liqToRemove;
        uint256 minUsdcOut;
        uint256 minWethOut;
        uint24  feeTierNew;
        int24   tickLowerNew;
        int24   tickUpperNew;
        uint256 amountUsdcDesired;
        uint256 amountWethDesired;
        uint256 minUsdcAdd;
        uint256 minWethAdd;
        uint256 deadline;
    }

    function rebalanceToNewLow(RebalanceParamsLow calldata p) external onlyOperator nonReentrant {
        if (positionIdUsdcWethLow == 0) revert NO_POSITION();

        if (p.liqToRemove > 0) {
            npm.decreaseLiquidity(
                INonfungiblePositionManager.DecreaseLiquidityParams({
                    tokenId: positionIdUsdcWethLow,
                    liquidity: p.liqToRemove,
                    amount0Min: p.minWethOut,
                    amount1Min: p.minUsdcOut,
                    deadline: p.deadline
                })
            );

            (uint256 feesWeth, uint256 feesUsdc) = npm.collect(
                INonfungiblePositionManager.CollectParams({
                    tokenId: positionIdUsdcWethLow,
                    recipient: address(this),
                    amount0Max: type(uint128).max,
                    amount1Max: type(uint128).max
                })
            );

            totalFeesUsdcFromLow += feesUsdc;
            totalFeesWethFromLow += feesWeth;
            feesOwedUsdcLow += feesUsdc;
            feesOwedWethLow += feesWeth;

            emit PositionFeesCollectedLow(positionIdUsdcWethLow, feesUsdc, feesWeth);
            emit FeesOwedUpdated(feesOwedUsdcLow, feesOwedWethLow, feesOwedUsdcHigh, feesOwedWethHigh, feesOwedUsdcExtra);
        }

        _approveAll();

        (uint256 newTokenId, uint128 newLiquidity, uint256 usedWeth, uint256 usedUsdc) = npm.mint(
            INonfungiblePositionManager.MintParams({
                token0: WETH,
                token1: USDC,
                fee: p.feeTierNew,
                tickLower: p.tickLowerNew,
                tickUpper: p.tickUpperNew,
                amount0Desired: p.amountWethDesired,
                amount1Desired: p.amountUsdcDesired,
                amount0Min: p.minWethAdd,
                amount1Min: p.minUsdcAdd,
                recipient: address(this),
                deadline: p.deadline
            })
        );

        emit RebalancedToNewLow(positionIdUsdcWethLow, newTokenId, p.feeTierNew, p.tickLowerNew, p.tickUpperNew);
        positionIdUsdcWethLow = newTokenId;
        newLiquidity; usedUsdc; usedWeth;
    }

    function _freeLiquidity(uint256 amountNeeded) internal {
        if (positionIdUsdcWethLow == 0 || amountNeeded == 0) return;

        (, , , uint128 liq, , ) = _getNpmPosition(positionIdUsdcWethLow);
        if (liq == 0) return;

        uint128 liqToRemove = liq;

        if (engine != address(0)) {
            uint256 tvlTotal = IBondFlowView(engine).tvl();
            uint16 allocBps = IBondFlowView(engine).vaultAllocBps();

            if (tvlTotal > 0 && allocBps > 0) {
                uint256 estVaultCap = (tvlTotal * uint256(allocBps)) / 10000;
                if (estVaultCap > 0) {
                    uint256 fractionBps = (amountNeeded * 11000) / estVaultCap;
                    if (fractionBps > 10000) fractionBps = 10000;
                    if (fractionBps == 0) fractionBps = 1000;
                    liqToRemove = uint128((uint256(liq) * fractionBps) / 10000);
                    if (liqToRemove == 0) liqToRemove = liq;
                }
            }
        }

        npm.decreaseLiquidity(
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: positionIdUsdcWethLow,
                liquidity: liqToRemove,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp + 600
            })
        );

        (uint256 feesWeth, uint256 feesUsdc) = npm.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: positionIdUsdcWethLow,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );

        totalFeesUsdcFromLow += feesUsdc;
        totalFeesWethFromLow += feesWeth;
        feesOwedUsdcLow += feesUsdc;
        feesOwedWethLow += feesWeth;

        uint256 preUsdc = usdcToken.balanceOf(address(this));
        uint256 preWeth = wethToken.balanceOf(address(this));

        _swapAllWethToUsdc(500, block.timestamp + 600);

        uint256 postUsdc = usdcToken.balanceOf(address(this));
        uint256 postWeth = wethToken.balanceOf(address(this));

        uint256 wethUsed = preWeth > postWeth ? (preWeth - postWeth) : 0;
        uint256 usdcGained = postUsdc > preUsdc ? (postUsdc - preUsdc) : 0;

        if (wethUsed > 0) {
            uint256 dec = wethUsed <= feesOwedWethLow ? wethUsed : feesOwedWethLow;
            feesOwedWethLow -= dec;
        }
        if (usdcGained > 0) {
            feesOwedUsdcLow += usdcGained;
        }

        emit FeesOwedUpdated(feesOwedUsdcLow, feesOwedWethLow, feesOwedUsdcHigh, feesOwedWethHigh, feesOwedUsdcExtra);
    }

    function _freeLiquidityAll() internal {
        if (positionIdUsdcWethLow != 0) {
            (, , , uint128 liqLow, , ) = _getNpmPosition(positionIdUsdcWethLow);
            if (liqLow > 0) {
                npm.decreaseLiquidity(
                    INonfungiblePositionManager.DecreaseLiquidityParams({
                        tokenId: positionIdUsdcWethLow,
                        liquidity: liqLow,
                        amount0Min: 0,
                        amount1Min: 0,
                        deadline: block.timestamp + 600
                    })
                );

                (uint256 feesWethLowNow, uint256 feesUsdcLowNow) = npm.collect(
                    INonfungiblePositionManager.CollectParams({
                        tokenId: positionIdUsdcWethLow,
                        recipient: address(this),
                        amount0Max: type(uint128).max,
                        amount1Max: type(uint128).max
                    })
                );

                totalFeesUsdcFromLow += feesUsdcLowNow;
                totalFeesWethFromLow += feesWethLowNow;
                feesOwedUsdcLow += feesUsdcLowNow;
                feesOwedWethLow += feesWethLowNow;
            }
        }

        if (positionIdUsdcWethHigh != 0) {
            (, , , uint128 liqHigh, , ) = _getNpmPosition(positionIdUsdcWethHigh);
            if (liqHigh > 0) {
                npm.decreaseLiquidity(
                    INonfungiblePositionManager.DecreaseLiquidityParams({
                        tokenId: positionIdUsdcWethHigh,
                        liquidity: liqHigh,
                        amount0Min: 0,
                        amount1Min: 0,
                        deadline: block.timestamp + 600
                    })
                );

                (uint256 feesWethHighNow, uint256 feesUsdcHighNow) = npm.collect(
                    INonfungiblePositionManager.CollectParams({
                        tokenId: positionIdUsdcWethHigh,
                        recipient: address(this),
                        amount0Max: type(uint128).max,
                        amount1Max: type(uint128).max
                    })
                );

                totalFeesUsdcFromHigh += feesUsdcHighNow;
                totalFeesWethFromHigh += feesWethHighNow;
                feesOwedUsdcHigh += feesUsdcHighNow;
                feesOwedWethHigh += feesWethHighNow;
            }
        }

        uint256 preUsdc = usdcToken.balanceOf(address(this));
        uint256 preWeth = wethToken.balanceOf(address(this));

        _swapAllWethToUsdc(500, block.timestamp + 600);

        uint256 postUsdc = usdcToken.balanceOf(address(this));
        uint256 postWeth = wethToken.balanceOf(address(this));

        uint256 wethUsed = preWeth > postWeth ? (preWeth - postWeth) : 0;
        uint256 usdcGained = postUsdc > preUsdc ? (postUsdc - preUsdc) : 0;

        if (wethUsed > 0) {
            uint256 usedLow = wethUsed <= feesOwedWethLow ? wethUsed : feesOwedWethLow;
            feesOwedWethLow -= usedLow;

            uint256 remaining = wethUsed - usedLow;
            uint256 usedHigh = remaining <= feesOwedWethHigh ? remaining : feesOwedWethHigh;
            feesOwedWethHigh -= usedHigh;

            uint256 totalForSplit = usedLow + usedHigh;
            if (usdcGained > 0 && totalForSplit > 0) {
                uint256 usdcToLow = (usdcGained * usedLow) / totalForSplit;
                uint256 usdcToHigh = usdcGained - usdcToLow;

                feesOwedUsdcLow += usdcToLow;
                feesOwedUsdcHigh += usdcToHigh;
            }
        }

        emit FeesOwedUpdated(feesOwedUsdcLow, feesOwedWethLow, feesOwedUsdcHigh, feesOwedWethHigh, feesOwedUsdcExtra);
    }

    function provideLiquidity(uint256 amountUsdc) external onlyEngine nonReentrant {
        if (amountUsdc == 0) revert ZERO();

        uint256 bal = usdcToken.balanceOf(address(this));
        if (bal < amountUsdc) {
            _freeLiquidity(amountUsdc);
            bal = usdcToken.balanceOf(address(this));
        }
        if (bal < amountUsdc) {
            _freeLiquidityAll();
            bal = usdcToken.balanceOf(address(this));
        }

        require(bal >= amountUsdc, "INSUFFICIENT_USDC");

        usdcToken.safeTransfer(engine, amountUsdc);
        emit PulledToEngine(amountUsdc);
    }

    function onEnginePull(uint256) external view onlyEngine {}

    function pushToEngine(uint256 amountUsdc) external onlyOperatorOrOwner nonReentrant {
        if (engine == address(0)) revert NOT_ENGINE();
        if (amountUsdc == 0) revert ZERO();
        usdcToken.safeTransfer(engine, amountUsdc);
        emit PulledToEngine(amountUsdc);
    }

    function pushToEngineAsInflow(uint256 amountUsdc) external onlyOperatorOrOwner nonReentrant {
        if (engine == address(0)) revert NOT_ENGINE();
        if (amountUsdc == 0) revert ZERO();

        usdcToken.safeTransfer(engine, amountUsdc);
        IEngineVault(engine).fundInflowFromVault(amountUsdc);

        emit PulledToEngine(amountUsdc);
        emit FeesPaidToEngine(amountUsdc);
    }

    function addUsdcOnlyFees(uint256 amountUsdc) external onlyOperatorOrOwner nonReentrant {
        if (amountUsdc == 0) revert ZERO();

        usdcToken.safeTransferFrom(msg.sender, address(this), amountUsdc);
        totalFeesUsdcExtra += amountUsdc;
        feesOwedUsdcExtra += amountUsdc;

        emit UsdcOnlyFeesAdded(amountUsdc);
        emit FeesOwedUpdated(feesOwedUsdcLow, feesOwedWethLow, feesOwedUsdcHigh, feesOwedWethHigh, feesOwedUsdcExtra);
    }

    function payAccumulatedFeesToEngine(
        uint24 feeTierLow,
        uint24 feeTierHigh,
        uint256 minUsdcOutFromLowWeth,
        uint256 minUsdcOutFromHighWeth,
        uint256 deadline
    ) external onlyOperatorOrOwner nonReentrant returns (uint256 sent) {
        if (engine == address(0)) revert NOT_ENGINE();

        uint256 wethBal = wethToken.balanceOf(address(this));

        if (feesOwedWethLow > 0 && wethBal > 0) {
            uint256 amountLow = wethBal <= feesOwedWethLow ? wethBal : feesOwedWethLow;

            uint256 outLow = _swapExactInput(
                address(wethToken),
                address(usdcToken),
                amountLow,
                minUsdcOutFromLowWeth,
                feeTierLow,
                deadline
            );

            feesOwedWethLow -= amountLow;
            feesOwedUsdcLow += outLow;

            wethBal = wethToken.balanceOf(address(this));
        }

        if (feesOwedWethHigh > 0 && wethBal > 0) {
            uint256 amountHigh = wethBal <= feesOwedWethHigh ? wethBal : feesOwedWethHigh;

            uint256 outHigh = _swapExactInput(
                address(wethToken),
                address(usdcToken),
                amountHigh,
                minUsdcOutFromHighWeth,
                feeTierHigh,
                deadline
            );

            feesOwedWethHigh -= amountHigh;
            feesOwedUsdcHigh += outHigh;
        }

        uint256 owedUsdc = feesOwedUsdcLow + feesOwedUsdcHigh + feesOwedUsdcExtra;
        uint256 balUsdc  = usdcToken.balanceOf(address(this));
        uint256 toSend   = owedUsdc <= balUsdc ? owedUsdc : balUsdc;

        if (toSend == 0) return 0;

        usdcToken.safeTransfer(engine, toSend);
        IEngineVault(engine).fundInflowFromVault(toSend);

        emit PulledToEngine(toSend);
        emit FeesPaidToEngine(toSend);

        sent = toSend;

        uint256 usedLow = toSend <= feesOwedUsdcLow ? toSend : feesOwedUsdcLow;
        feesOwedUsdcLow -= usedLow;

        uint256 rem = toSend - usedLow;
        if (rem > 0) {
            uint256 usedHigh = rem <= feesOwedUsdcHigh ? rem : feesOwedUsdcHigh;
            feesOwedUsdcHigh -= usedHigh;
            rem -= usedHigh;
        }

        if (rem > 0) {
            uint256 usedExtra = rem <= feesOwedUsdcExtra ? rem : feesOwedUsdcExtra;
            feesOwedUsdcExtra -= usedExtra;
        }

        emit FeesOwedUpdated(feesOwedUsdcLow, feesOwedWethLow, feesOwedUsdcHigh, feesOwedWethHigh, feesOwedUsdcExtra);
    }

    function getFeesOwedRaw()
        external
        view
        returns (
            uint256 usdcLow,
            uint256 wethLow,
            uint256 usdcHigh,
            uint256 wethHigh,
            uint256 usdcExtra
        )
    {
        return (feesOwedUsdcLow, feesOwedWethLow, feesOwedUsdcHigh, feesOwedWethHigh, feesOwedUsdcExtra);
    }

    function getVaultBalances()
        external
        view
        returns (
            uint256 balUsdc,
            uint256 balWeth
        )
    {
        return (usdcToken.balanceOf(address(this)), wethToken.balanceOf(address(this)));
    }

    function getFeesOwedInUsdcGivenWethPrice(uint256 priceWethInUsdc1e18)
        external
        view
        returns (
            uint256 usdcEqLow,
            uint256 usdcEqHigh,
            uint256 totalUsdcEq
        )
    {
        uint256 wethLowEq  = (feesOwedWethLow  * priceWethInUsdc1e18) / 1e18;
        uint256 wethHighEq = (feesOwedWethHigh * priceWethInUsdc1e18) / 1e18;

        usdcEqLow  = feesOwedUsdcLow  + wethLowEq;
        usdcEqHigh = feesOwedUsdcHigh + wethHighEq;

        totalUsdcEq = usdcEqLow + usdcEqHigh + feesOwedUsdcExtra;
    }

    function burnPosition(uint256 tokenId) external onlyOperator nonReentrant {
    if (tokenId == 0) revert NO_POSITION();

    (, , , uint128 liq, , ) = _getNpmPosition(tokenId);

    if (liq > 0) {
        npm.decreaseLiquidity(
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: tokenId,
                liquidity: liq,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp + 600
            })
        );
    }

    (uint256 feesWeth, uint256 feesUsdc) = npm.collect(
        INonfungiblePositionManager.CollectParams({
            tokenId: tokenId,
            recipient: address(this),
            amount0Max: type(uint128).max,
            amount1Max: type(uint128).max
        })
    );

    if (tokenId == positionIdUsdcWethLow) {
        totalFeesUsdcFromLow += feesUsdc;
        totalFeesWethFromLow += feesWeth;
        feesOwedUsdcLow      += feesUsdc;
        feesOwedWethLow      += feesWeth;

        emit PositionFeesCollectedLow(tokenId, feesUsdc, feesWeth);
    } else if (tokenId == positionIdUsdcWethHigh) {
        totalFeesUsdcFromHigh += feesUsdc;
        totalFeesWethFromHigh += feesWeth;
        feesOwedUsdcHigh      += feesUsdc;
        feesOwedWethHigh      += feesWeth;

        emit PositionFeesCollectedHigh(tokenId, feesUsdc, feesWeth);
    }

    emit FeesOwedUpdated(
        feesOwedUsdcLow,
        feesOwedWethLow,
        feesOwedUsdcHigh,
        feesOwedWethHigh,
        feesOwedUsdcExtra
    );

    npm.burn(tokenId);

     if (tokenId == positionIdUsdcWethLow)  positionIdUsdcWethLow  = 0;
    if (tokenId == positionIdUsdcWethHigh) positionIdUsdcWethHigh = 0;
}

}

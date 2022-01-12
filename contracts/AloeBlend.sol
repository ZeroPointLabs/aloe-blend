// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.10;

import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "./libraries/FullMath.sol";
import "./libraries/TickMath.sol";
import "./libraries/Silo.sol";
import "./libraries/Uniswap.sol";

import "./interfaces/IAloeBlend.sol";
import "./interfaces/IFactory.sol";
import "./interfaces/IVolatilityOracle.sol";

import "./AloeBlendERC20.sol";
import "./UniswapHelper.sol";

/*
                              #                                                                    
                             ###                                                                   
                             #####                                                                 
          #                 #######                                *###*                           
           ###             #########                         ########                              
           #####         ###########                   ###########                                 
           ########    ############               ############                                     
            ########    ###########         *##############                                        
           ###########   ########      #################                                           
           ############   ###      #################                                               
           ############       ##################                                                   
          #############    #################*         *#############*                              
         ##############    #############      #####################################                
        ###############   ####******      #######################*                                 
      ################                                                                             
    #################   *############################*                                             
      ##############    ######################################                                     
          ########    ################*                     **######*                              
              ###    ###                                                                           
*/

uint256 constant Q96 = 2**96;

contract AloeBlend is AloeBlendERC20, UniswapHelper, IAloeBlend {
    using SafeERC20 for IERC20;
    using Uniswap for Uniswap.Position;
    using Silo for ISilo;

    /// @inheritdoc IAloeBlendImmutables
    uint24 public constant RECENTERING_INTERVAL = 24 hours; // aim to recenter once per day

    /// @inheritdoc IAloeBlendImmutables
    uint24 public constant MIN_WIDTH = 402; // 1% of inventory in primary Uniswap position

    /// @inheritdoc IAloeBlendImmutables
    uint24 public constant MAX_WIDTH = 27728; // 50% of inventory in primary Uniswap position

    /// @inheritdoc IAloeBlendImmutables
    uint8 public constant K = 10; // maintenance budget should cover at least 10 rebalances

    /// @inheritdoc IAloeBlendImmutables
    uint8 public constant B = 2; // primary Uniswap position should cover 95% of trading activity

    /// @inheritdoc IAloeBlendImmutables
    uint8 public constant MAINTENANCE_FEE = 10; // 1/10th of earnings from primary Uniswap position

    /// @inheritdoc IAloeBlendImmutables
    IVolatilityOracle public immutable volatilityOracle;

    /// @inheritdoc IAloeBlendImmutables
    ISilo public immutable silo0;

    /// @inheritdoc IAloeBlendImmutables
    ISilo public immutable silo1;

    struct PackedSlot {
        int24 primaryLower;
        int24 primaryUpper;
        int24 limitLower;
        int24 limitUpper;
        uint48 recenterTimestamp;
        bool maintenanceIsSustainable;
        bool locked;
    }

    /// @inheritdoc IAloeBlendState
    PackedSlot public packedSlot;

    /// @inheritdoc IAloeBlendState
    uint256 public silo0Basis;

    /// @inheritdoc IAloeBlendState
    uint256 public silo1Basis;

    /// @inheritdoc IAloeBlendState
    uint256 public maintenanceBudget0;

    /// @inheritdoc IAloeBlendState
    uint256 public maintenanceBudget1;

    uint224[10] public rewardPerGas0Array;

    uint224[10] public rewardPerGas1Array;

    uint224 public rewardPerGas0Accumulator;

    uint224 public rewardPerGas1Accumulator;

    /// @dev Required for some silos
    receive() external payable {}

    constructor(
        IUniswapV3Pool _uniPool,
        ISilo _silo0,
        ISilo _silo1
    )
        AloeBlendERC20(
            // ex: Aloe Blend USDC/WETH
            string(
                abi.encodePacked(
                    "Aloe Blend ",
                    IERC20Metadata(_uniPool.token0()).symbol(),
                    "/",
                    IERC20Metadata(_uniPool.token1()).symbol()
                )
            )
        )
        UniswapHelper(_uniPool)
    {
        volatilityOracle = IFactory(msg.sender).VOLATILITY_ORACLE();
        silo0 = _silo0;
        silo1 = _silo1;
    }

    /// @inheritdoc IAloeBlendActions
    function deposit(
        uint256 amount0Max,
        uint256 amount1Max,
        uint256 amount0Min,
        uint256 amount1Min
    )
        external
        returns (
            uint256 shares,
            uint256 amount0,
            uint256 amount1
        )
    {
        require(amount0Max != 0 || amount1Max != 0, "Aloe: 0 deposit");
        // Reentrancy guard is embedded in `_loadPackedSlot` to save gas
        (Uniswap.Position memory primary, Uniswap.Position memory limit, , ) = _loadPackedSlot();
        packedSlot.locked = true;

        // Poke all assets
        primary.poke();
        limit.poke();
        silo0.delegate_poke();
        silo1.delegate_poke();

        // Fetch instantaneous price from Uniswap
        (uint160 sqrtPriceX96, , , , , , ) = UNI_POOL.slot0();

        (uint256 inventory0, uint256 inventory1) = getInventory();
        (shares, amount0, amount1) = _computeLPShares(
            totalSupply,
            inventory0,
            inventory1,
            amount0Max,
            amount1Max,
            sqrtPriceX96
        );
        require(shares != 0, "Aloe: 0 shares");
        require(amount0 >= amount0Min, "Aloe: amount0 too low");
        require(amount1 >= amount1Min, "Aloe: amount1 too low");

        // Pull in tokens from sender
        TOKEN0.safeTransferFrom(msg.sender, address(this), amount0);
        TOKEN1.safeTransferFrom(msg.sender, address(this), amount1);

        // Mint shares
        _mint(msg.sender, shares);
        emit Deposit(msg.sender, shares, amount0, amount1);
        packedSlot.locked = false;
    }

    /// @inheritdoc IAloeBlendActions
    function withdraw(
        uint256 shares,
        uint256 amount0Min,
        uint256 amount1Min
    ) external returns (uint256 amount0, uint256 amount1) {
        require(shares != 0, "Aloe: 0 shares");
        // Reentrancy guard is embedded in `_loadPackedSlot` to save gas
        (Uniswap.Position memory primary, Uniswap.Position memory limit, , ) = _loadPackedSlot();
        packedSlot.locked = true;

        // Poke silos to ensure reported balances are correct
        silo0.delegate_poke();
        silo1.delegate_poke();

        uint256 _totalSupply = totalSupply;
        uint256 a;
        uint256 b;
        uint256 c;
        uint256 d;

        // Compute user's portion of token0 from contract + silo0
        c = _balance0();
        a = silo0Basis;
        b = silo0.balanceOf(address(this));
        a = b > a ? (b - a) / MAINTENANCE_FEE : 0; // interest / MAINTENANCE_FEE
        amount0 = FullMath.mulDiv(c + b - a, shares, _totalSupply);
        // Withdraw from silo0 if contract balance can't cover what user is owed
        if (amount0 > c) {
            c = a + amount0 - c;
            silo0.delegate_withdraw(c);
            maintenanceBudget0 += a;
            silo0Basis = b - c;
        }

        // Compute user's portion of token1 from contract + silo1
        c = _balance1();
        a = silo1Basis;
        b = silo1.balanceOf(address(this));
        a = b > a ? (b - a) / MAINTENANCE_FEE : 0; // interest / MAINTENANCE_FEE
        amount1 = FullMath.mulDiv(c + b - a, shares, _totalSupply);
        // Withdraw from silo1 if contract balance can't cover what user is owed
        if (amount1 > c) {
            c = a + amount1 - c;
            silo1.delegate_withdraw(c);
            maintenanceBudget1 += a;
            silo1Basis = b - c;
        }

        // Withdraw user's portion of the primary position
        {
            (uint128 liquidity, , , , ) = primary.info();
            (a, b, c, d) = primary.withdraw(uint128(FullMath.mulDiv(liquidity, shares, _totalSupply)));
            amount0 += a;
            amount1 += b;
            a = c / MAINTENANCE_FEE;
            b = d / MAINTENANCE_FEE;
            amount0 += FullMath.mulDiv(c - a, shares, _totalSupply);
            amount1 += FullMath.mulDiv(d - b, shares, _totalSupply);
            maintenanceBudget0 += a;
            maintenanceBudget1 += b;
        }

        // Withdraw user's portion of the limit order
        if (limit.lower != limit.upper) {
            (uint128 liquidity, , , , ) = limit.info();
            (a, b, c, d) = limit.withdraw(uint128(FullMath.mulDiv(liquidity, shares, _totalSupply)));
            amount0 += a + FullMath.mulDiv(c, shares, _totalSupply);
            amount1 += b + FullMath.mulDiv(d, shares, _totalSupply);
        }

        // Check constraints
        require(amount0 >= amount0Min, "Aloe: amount0 too low");
        require(amount1 >= amount1Min, "Aloe: amount1 too low");

        // Transfer tokens
        TOKEN0.safeTransfer(msg.sender, amount0);
        TOKEN1.safeTransfer(msg.sender, amount1);

        // Burn shares
        _burn(msg.sender, shares);
        emit Withdraw(msg.sender, shares, amount0, amount1);
        packedSlot.locked = false;
    }

    struct RebalanceCache {
        uint160 sqrtPriceX96;
        uint96 magic;
        int24 tick;
        uint24 w;
        uint32 urgency;
        uint224 priceX96;
    }

    /// @inheritdoc IAloeBlendActions
    function rebalance(uint8 rewardToken) external {
        uint32 gasStart = uint32(gasleft());
        // Reentrancy guard is embedded in `_loadPackedSlot` to save gas
        (
            Uniswap.Position memory primary,
            Uniswap.Position memory limit,
            uint48 recenterTimestamp,
            bool maintenanceIsSustainable
        ) = _loadPackedSlot();
        packedSlot.locked = true;

        RebalanceCache memory cache;
        (cache.sqrtPriceX96, cache.tick, , , , , ) = UNI_POOL.slot0();
        cache.priceX96 = uint224(FullMath.mulDiv(cache.sqrtPriceX96, cache.sqrtPriceX96, Q96));
        // Get rebalance urgency (based on time elapsed since previous rebalance)
        cache.urgency = getRebalanceUrgency();

        (uint128 liquidity, , , , ) = limit.info();
        limit.withdraw(liquidity);

        (uint256 inventory0, uint256 inventory1, uint256 fluid0, uint256 fluid1) = _getInventory(
            primary,
            limit,
            cache.sqrtPriceX96,
            false
        );
        uint256 ratio = FullMath.mulDiv(
            10_000,
            inventory0,
            inventory0 + FullMath.mulDiv(inventory1, Q96, cache.priceX96)
        );

        if (ratio < 4900) {
            // Attempt to sell token1 for token0. Place a limit order below the active range
            limit.upper = TickMath.floor(cache.tick, TICK_SPACING);
            limit.lower = limit.upper - TICK_SPACING;
            // Choose amount1 such that ratio will be 50/50 once the limit order is pushed through. Division by 2
            // works for small tickSpacing. Also have to constrain to fluid1 since we're not yet withdrawing from
            // primary Uniswap position.
            uint256 amount1 = (inventory1 - FullMath.mulDiv(inventory0, cache.priceX96, Q96)) >> 1;
            if (amount1 > fluid1) amount1 = fluid1;
            // Withdraw requisite amount from silo
            uint256 balance1 = _balance1();
            if (balance1 < amount1) silo1.delegate_withdraw(amount1 - balance1);
            // Deposit to new limit order and store bounds
            limit.deposit(limit.liquidityForAmount1(amount1));
        } else if (ratio > 5100) {
            // Attempt to sell token0 for token1. Place a limit order above the active range
            limit.lower = TickMath.ceil(cache.tick, TICK_SPACING);
            limit.upper = limit.lower + TICK_SPACING;
            // Choose amount0 such that ratio will be 50/50 once the limit order is pushed through. Division by 2
            // works for small tickSpacing. Also have to constrain to fluid0 since we're not yet withdrawing from
            // primary Uniswap position.
            uint256 amount0 = (inventory0 - FullMath.mulDiv(inventory1, Q96, cache.priceX96)) >> 1;
            if (amount0 > fluid0) amount0 = fluid0;
            // Withdraw requisite amount from silo
            uint256 balance0 = _balance0();
            if (balance0 < amount0) silo0.delegate_withdraw(amount0 - balance0);
            // Deposit to new limit order and store bounds
            limit.deposit(limit.liquidityForAmount0(amount0));
        } else {
            recenter(cache, primary, inventory0, inventory1);
            recenterTimestamp = uint48(block.timestamp);
        }

        // Poke primary position and withdraw fees so that maintenance budget can grow
        {
            (, , uint256 earned0, uint256 earned1) = primary.withdraw(0);
            _earmarkSomeForMaintenance(earned0, earned1);
        }

        // Reward caller
        {
            uint32 gasUsed = uint32(21000 + gasStart - gasleft());
            if (rewardToken == 0) {
                // computations
                uint224 rewardPerGas = uint224(FullMath.mulDiv(rewardPerGas0Accumulator, cache.urgency, 10_000));
                uint256 rebalanceIncentive = gasUsed * rewardPerGas;
                // constraints
                if (rewardPerGas == 0 || rebalanceIncentive > maintenanceBudget0)
                    rebalanceIncentive = maintenanceBudget0;
                // payout
                TOKEN0.safeTransfer(msg.sender, rebalanceIncentive);
                // accounting
                pushRewardPerGas0(rewardPerGas, 0);
                maintenanceBudget0 -= rebalanceIncentive;
                if (maintenanceBudget0 > K * rewardPerGas * block.gaslimit)
                    maintenanceBudget0 = K * rewardPerGas * block.gaslimit;
            } else {
                // computations
                uint224 rewardPerGas = uint224(FullMath.mulDiv(rewardPerGas1Accumulator, cache.urgency, 10_000));
                uint256 rebalanceIncentive = gasUsed * rewardPerGas;
                // constraints
                if (rewardPerGas == 0 || rebalanceIncentive > maintenanceBudget1)
                    rebalanceIncentive = maintenanceBudget1;
                // payout
                TOKEN1.safeTransfer(msg.sender, rebalanceIncentive);
                // accounting
                pushRewardPerGas1(rewardPerGas, 0);
                maintenanceBudget1 -= rebalanceIncentive;
                if (maintenanceBudget1 > K * rewardPerGas * block.gaslimit)
                    maintenanceBudget1 = K * rewardPerGas * block.gaslimit;
            }
        }

        emit Rebalance(cache.urgency, ratio, totalSupply, inventory0, inventory1);
        _unlockAndStorePackedSlot(primary, limit, recenterTimestamp, maintenanceIsSustainable);
    }

    function recenter(
        RebalanceCache memory cache,
        Uniswap.Position memory _primary,
        uint256 inventory0,
        uint256 inventory1
    ) private returns (Uniswap.Position memory) {
        uint256 sigma = volatilityOracle.estimate24H(UNI_POOL, cache.sqrtPriceX96, cache.tick);
        cache.w = _computeNextPositionWidth(sigma);

        // Exit primary Uniswap position
        {
            (uint128 liquidity, , , , ) = _primary.info();
            (, , uint256 earned0, uint256 earned1) = _primary.withdraw(liquidity);
            _earmarkSomeForMaintenance(earned0, earned1);
        }

        // Compute amounts that should be placed in new Uniswap position
        uint256 amount0;
        uint256 amount1;
        cache.w = cache.w >> 1;
        (cache.magic, amount0, amount1) = _computeMagicAmounts(inventory0, inventory1, cache.priceX96, cache.w);

        uint256 balance0 = _balance0();
        uint256 balance1 = _balance1();
        bool hasExcessToken0 = balance0 > amount0;
        bool hasExcessToken1 = balance1 > amount1;

        // Because of cToken exchangeRate rounding, we may withdraw too much
        // here. That's okay; dust will just sit in contract till next rebalance
        if (!hasExcessToken0) silo0.delegate_withdraw(amount0 - balance0);
        if (!hasExcessToken1) silo1.delegate_withdraw(amount1 - balance1);

        // Update primary position's ticks
        _primary.lower = TickMath.floor(cache.tick - int24(cache.w), TICK_SPACING);
        _primary.upper = TickMath.ceil(cache.tick + int24(cache.w), TICK_SPACING);
        if (_primary.lower < TickMath.MIN_TICK) _primary.lower = TickMath.MIN_TICK;
        if (_primary.upper > TickMath.MAX_TICK) _primary.upper = TickMath.MAX_TICK;

        // Place some liquidity in Uniswap
        (amount0, amount1) = _primary.deposit(_primary.liquidityForAmounts(cache.sqrtPriceX96, amount0, amount1));

        // Place excess into silos
        if (hasExcessToken0) silo0.delegate_deposit(balance0 - amount0);
        if (hasExcessToken1) silo1.delegate_deposit(balance1 - amount1);

        emit Recenter(_primary.lower, _primary.upper, cache.magic);
        return _primary;
    }

    /// @dev Earmark some earned fees for maintenance, according to `maintenanceFee`. Return what's leftover
    function _earmarkSomeForMaintenance(uint256 earned0, uint256 earned1) private returns (uint256, uint256) {
        uint256 toMaintenance;

        unchecked {
            // Accrue token0
            toMaintenance = earned0 / MAINTENANCE_FEE;
            earned0 -= toMaintenance;
            maintenanceBudget0 += toMaintenance;
            // Accrue token1
            toMaintenance = earned1 / MAINTENANCE_FEE;
            earned1 -= toMaintenance;
            maintenanceBudget1 += toMaintenance;
        }

        return (earned0, earned1);
    }

    function pushRewardPerGas0(uint224 rewardPerGas0, uint16 _epoch) private {
        unchecked {
            uint8 idx = uint8(_epoch % 10);

            rewardPerGas0 /= 10;
            rewardPerGas0Accumulator = rewardPerGas0Accumulator + rewardPerGas0 - rewardPerGas0Array[idx];
            rewardPerGas0Array[idx] = rewardPerGas0;
        }
    }

    function pushRewardPerGas1(uint224 rewardPerGas1, uint16 _epoch) private {
        unchecked {
            uint8 idx = uint8(_epoch % 10);

            rewardPerGas1 /= 10;
            rewardPerGas1Accumulator = rewardPerGas1Accumulator + rewardPerGas1 - rewardPerGas1Array[idx];
            rewardPerGas1Array[idx] = rewardPerGas1;
        }
    }

    function _unlockAndStorePackedSlot(
        Uniswap.Position memory _primary,
        Uniswap.Position memory _limit,
        uint48 _recenterTimestamp,
        bool maintenanceIsSustainable
    ) private {
        packedSlot = PackedSlot(
            _primary.lower,
            _primary.upper,
            _limit.lower,
            _limit.upper,
            _recenterTimestamp,
            maintenanceIsSustainable,
            false
        );
    }

    // ⬇️⬇️⬇️⬇️ VIEW FUNCTIONS ⬇️⬇️⬇️⬇️  ------------------------------------------------------------------------------

    /// @dev TODO
    function _loadPackedSlot()
        private
        view
        returns (
            Uniswap.Position memory,
            Uniswap.Position memory,
            uint48,
            bool
        )
    {
        PackedSlot memory _packedSlot = packedSlot;
        require(!_packedSlot.locked);
        return (
            Uniswap.Position(UNI_POOL, _packedSlot.primaryLower, _packedSlot.primaryUpper),
            Uniswap.Position(UNI_POOL, _packedSlot.limitLower, _packedSlot.limitUpper),
            _packedSlot.recenterTimestamp,
            _packedSlot.maintenanceIsSustainable
        );
    }

    /// @inheritdoc IAloeBlendDerivedState
    function getRebalanceUrgency() public view returns (uint32 urgency) {
        urgency = uint32(FullMath.mulDiv(10_000, block.timestamp - packedSlot.recenterTimestamp, RECENTERING_INTERVAL));
    }

    /// @inheritdoc IAloeBlendDerivedState
    function getInventory() public view returns (uint256 inventory0, uint256 inventory1) {
        (uint160 sqrtPriceX96, , , , , , ) = UNI_POOL.slot0();
        (Uniswap.Position memory primary, Uniswap.Position memory limit, , ) = _loadPackedSlot();
        (inventory0, inventory1, , ) = _getInventory(primary, limit, sqrtPriceX96, true);
    }

    function _getInventory(
        Uniswap.Position memory primary,
        Uniswap.Position memory limit,
        uint160 sqrtPriceX96,
        bool includeLimit
    )
        private
        view
        returns (
            uint256 inventory0,
            uint256 inventory1,
            uint256 availableForLimit0,
            uint256 availableForLimit1
        )
    {
        if (includeLimit) {
            (availableForLimit0, availableForLimit1, ) = limit.collectableAmountsAsOfLastPoke(sqrtPriceX96);
        }
        // Everything in silos + everything in the contract, except maintenance budget
        availableForLimit0 += silo0.balanceOf(address(this)) + _balance0();
        availableForLimit1 += silo1.balanceOf(address(this)) + _balance1();
        // Everything in primary Uniswap position. Limit order is placed without moving this, so its
        // amounts don't get added to availableForLimitX.
        (inventory0, inventory1, ) = primary.collectableAmountsAsOfLastPoke(sqrtPriceX96);
        inventory0 += availableForLimit0;
        inventory1 += availableForLimit1;
    }

    /// @dev TODO
    function _balance0() private view returns (uint256) {
        return TOKEN0.balanceOf(address(this)) - maintenanceBudget0;
    }

    /// @dev TODO
    function _balance1() private view returns (uint256) {
        return TOKEN1.balanceOf(address(this)) - maintenanceBudget1;
    }

    // ⬆️⬆️⬆️⬆️ VIEW FUNCTIONS ⬆️⬆️⬆️⬆️  ------------------------------------------------------------------------------
    // ⬇️⬇️⬇️⬇️ PURE FUNCTIONS ⬇️⬇️⬇️⬇️  ------------------------------------------------------------------------------

    /// @dev Computes position width based on sigma (volatility)
    function _computeNextPositionWidth(uint256 sigma) internal pure returns (uint24) {
        if (sigma <= 5.024579e15) return MIN_WIDTH;
        if (sigma >= 3.000058e17) return MAX_WIDTH;
        sigma *= B; // scale by a constant factor to increase confidence

        unchecked {
            uint160 ratio = uint160((Q96 * (1e18 + sigma)) / (1e18 - sigma));
            return uint24(TickMath.getTickAtSqrtRatio(ratio)) >> 1;
        }
    }

    /// @dev Computes amounts that should be placed in primary Uniswap position to maintain 50/50 inventory ratio.
    /// Doesn't revert as long as MIN_WIDTH <= _halfWidth * 2 <= MAX_WIDTH
    // ✅
    function _computeMagicAmounts(
        uint256 inventory0,
        uint256 inventory1,
        uint224 priceX96,
        uint24 halfWidth
    )
        internal
        pure
        returns (
            uint96 magic,
            uint256 amount0,
            uint256 amount1
        )
    {
        magic = uint96(Q96 - TickMath.getSqrtRatioAtTick(-int24(halfWidth)));
        if (FullMath.mulDiv(inventory0, priceX96, Q96) > inventory1) {
            amount1 = FullMath.mulDiv(inventory1, magic, Q96);
            amount0 = FullMath.mulDiv(amount1, Q96, priceX96);
        } else {
            amount0 = FullMath.mulDiv(inventory0, magic, Q96);
            amount1 = FullMath.mulDiv(amount0, priceX96, Q96);
        }
    }

    /// @dev Computes the largest possible `amount0` and `amount1` such that they match the current inventory ratio,
    /// but are not greater than `_amount0Max` and `_amount1Max` respectively. May revert if the following are true:
    ///     _totalSupply * _amount0Max / _inventory0 > type(uint256).max
    ///     _totalSupply * _amount1Max / _inventory1 > type(uint256).max
    /// This is okay because it only blocks deposit (not withdraw). Can also workaround by depositing smaller amounts
    // ✅
    function _computeLPShares(
        uint256 _totalSupply,
        uint256 _inventory0,
        uint256 _inventory1,
        uint256 _amount0Max,
        uint256 _amount1Max,
        uint160 _sqrtPriceX96
    )
        internal
        pure
        returns (
            uint256 shares,
            uint256 amount0,
            uint256 amount1
        )
    {
        // If total supply > 0, pool can't be empty
        assert(_totalSupply == 0 || _inventory0 != 0 || _inventory1 != 0);

        if (_totalSupply == 0) {
            // For first deposit, enforce 50/50 ratio manually
            uint224 priceX96 = uint224(FullMath.mulDiv(_sqrtPriceX96, _sqrtPriceX96, Q96));
            amount0 = FullMath.mulDiv(_amount1Max, Q96, priceX96);

            if (amount0 < _amount0Max) {
                amount1 = _amount1Max;
                shares = amount1;
            } else {
                amount0 = _amount0Max;
                amount1 = FullMath.mulDiv(amount0, priceX96, Q96);
                shares = amount0;
            }
        } else if (_inventory0 == 0) {
            amount1 = _amount1Max;
            shares = FullMath.mulDiv(amount1, _totalSupply, _inventory1);
        } else if (_inventory1 == 0) {
            amount0 = _amount0Max;
            shares = FullMath.mulDiv(amount0, _totalSupply, _inventory0);
        } else {
            // The branches of this ternary are logically identical, but must be separate to avoid overflow
            bool cond = _inventory0 < _inventory1
                ? FullMath.mulDiv(_amount1Max, _inventory0, _inventory1) < _amount0Max
                : _amount1Max < FullMath.mulDiv(_amount0Max, _inventory1, _inventory0);

            if (cond) {
                amount1 = _amount1Max;
                amount0 = FullMath.mulDiv(amount1, _inventory0, _inventory1);
                shares = FullMath.mulDiv(amount1, _totalSupply, _inventory1);
            } else {
                amount0 = _amount0Max;
                amount1 = FullMath.mulDiv(amount0, _inventory1, _inventory0);
                shares = FullMath.mulDiv(amount0, _totalSupply, _inventory0);
            }
        }
    }
}

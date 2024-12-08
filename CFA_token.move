module forest_protection::token {
    // Version: 1.0.0
    use sui::coin::{Self, Coin};
    use sui::sui::SUI;
    use sui::balance::{Self, Balance};
    use sui::event;

    /// Main token economics structure
    public struct TokenEconomics has key {
        id: UID,
        total_supply: u64,
        base_price: u64,        // Base price in SUI
        price_multiplier: u64,   // Multiplier for bonding curve
        max_reward_rate: u64,    // Maximum reward percentage (50% = 5000)
        min_reward_rate: u64,    // Minimum reward percentage (10% = 1000)
        treasury: Balance<SUI>   // Protocol treasury
    }

    /// Staking pool structure
    public struct StakingPool has key {
        id: UID,
        forest_id: ID,
        total_staked: Balance<SUI>,
        current_reward_rate: u64,
        period_end: u64,
        is_active: bool,
        min_stake_amount: u64,
        early_unstake_fee: u64,
        oracle_address: address
    }

    /// Stake token structure - represents user's stake
    public struct StakeToken has key, store {
        id: UID,
        pool_id: ID,
        amount: u64,
        staked_at: u64,
        owner: address,
        bonus_multiplier: u64
    }

    /// Events
    public struct PriceUpdated has copy, drop {
        new_price: u64,
        total_supply: u64
    }

    public struct RewardRateUpdated has copy, drop {
        new_rate: u64,
        total_supply: u64
    }

    public struct StakeCreated has copy, drop {
        token_id: ID,
        amount: u64,
        owner: address
    }

    /// Constants
    const PRECISION: u64 = 10000;
    const INITIAL_PRICE: u64 = 1000000; // 1 SUI
    const PRICE_MULTIPLIER: u64 = 11000; // 1.1 in percentage
    
    /// Errors
    const E_INSUFFICIENT_AMOUNT: u64 = 0;
    const E_POOL_INACTIVE: u64 = 1;
    const E_UNAUTHORIZED: u64 = 2;
    const E_PERIOD_NOT_ENDED: u64 = 3;

    /// Initialize token economics - called once during deployment
    public fun initialize_economics(ctx: &mut TxContext) {
        let economics = TokenEconomics {
            id: object::new(ctx),
            total_supply: 0,
            base_price: INITIAL_PRICE,
            price_multiplier: PRICE_MULTIPLIER,
            max_reward_rate: 5000,
            min_reward_rate: 1000,
            treasury: balance::zero()
        };
        
        transfer::share_object(economics);
    }

    /// Create new staking pool
    public entry fun create_pool(
        forest_id: ID,
        period_length: u64,
        min_stake: u64,
        ctx: &mut TxContext
    ) {
        let pool = StakingPool {
            id: object::new(ctx),
            forest_id,
            total_staked: balance::zero(),
            current_reward_rate: 5000, // Start with max rate
            period_end: tx_context::epoch(ctx) + period_length,
            is_active: true,
            min_stake_amount: min_stake,
            early_unstake_fee: 1000, // 10% fee
            oracle_address: tx_context::sender(ctx)
        };
        
        transfer::share_object(pool);
    }

    /// Retrieve current token economics
    public fun get_token_economics(economics: TokenEconomics): TokenEconomics {
        economics
    }

    /// Retrieve current staking pool information
    public fun get_staking_pool(pool: StakingPool): StakingPool {
        pool
    }

    /// Calculate current token price based on supply
    public fun calculate_current_price(economics: &TokenEconomics): u64 {
        let supply_factor = (economics.total_supply * economics.price_multiplier) / PRECISION;
        economics.base_price + supply_factor
    }

    /// Calculate current reward rate based on supply
    public fun calculate_reward_rate(economics: &TokenEconomics): u64 {
        let supply_percentage = (economics.total_supply * PRECISION) / 1000000;
        
        if (supply_percentage >= PRECISION) {
            return economics.min_reward_rate
        };
        
        let rate_range = economics.max_reward_rate - economics.min_reward_rate;
        let remaining_percentage = PRECISION - supply_percentage;
        
        economics.min_reward_rate + ((rate_range * remaining_percentage) / PRECISION)
    }

    /// Buy tokens and stake them
    public entry fun buy_and_stake(
        economics: &mut TokenEconomics,
        pool: &mut StakingPool,
        payment: &mut Coin<SUI>,
        amount: u64,
        ctx: &mut TxContext
    ) {
        assert!(amount >= pool.min_stake_amount, E_INSUFFICIENT_AMOUNT);
        assert!(pool.is_active, E_POOL_INACTIVE);

        let current_price = calculate_current_price(economics);
        let total_cost = current_price * amount;
        
        assert!(coin::value(payment) >= total_cost, E_INSUFFICIENT_AMOUNT);

        // Fee distribution
        let protocol_fee = total_cost / 10; // 10% goes to treasury
        let stake_amount = total_cost - protocol_fee;

        // Treasury funding
        let fee_payment = coin::split(payment, protocol_fee, ctx);
        balance::join(&mut economics.treasury, coin::into_balance(fee_payment));

        // Create stake token
        let stake_token = StakeToken {
            id: object::new(ctx),
            pool_id: object::uid_to_inner(&pool.id),
            amount: stake_amount,
            staked_at: tx_context::epoch(ctx),
            owner: tx_context::sender(ctx),
            bonus_multiplier: calculate_bonus_multiplier(amount)
        };

        // Update economics
        economics.total_supply = economics.total_supply + amount;
        pool.current_reward_rate = calculate_reward_rate(economics);

        // Emit events
        event::emit(PriceUpdated {
            new_price: calculate_current_price(economics),
            total_supply: economics.total_supply
        });

        event::emit(RewardRateUpdated {
            new_rate: pool.current_reward_rate,
            total_supply: economics.total_supply
        });

        event::emit(StakeCreated {
            token_id: object::uid_to_inner(&stake_token.id),
            amount: stake_amount,
            owner: tx_context::sender(ctx)
        });

        sui::transfer::public_transfer(stake_token, tx_context::sender(ctx));
    }

    /// Claim rewards if no forest fire occurred
    public entry fun claim_rewards(
        pool: &mut StakingPool,
        stake_token: &mut StakeToken,
        ctx: &mut TxContext
    ) {
        assert!(pool.is_active, E_POOL_INACTIVE);
        assert!(tx_context::epoch(ctx) >= pool.period_end, E_PERIOD_NOT_ENDED);
        assert!(stake_token.owner == tx_context::sender(ctx), E_UNAUTHORIZED);

        let reward_rate = (pool.current_reward_rate * stake_token.bonus_multiplier) / 100;
        let reward_amount = (stake_token.amount * reward_rate) / PRECISION;
        
        // Return stake + rewards
        let return_amount = stake_token.amount + reward_amount;
        let return_coin = coin::from_balance(
            balance::split(&mut pool.total_staked, return_amount),
            ctx
        );

        // Transfer the return_coin to the stake token owner
        sui::transfer::public_transfer(return_coin, stake_token.owner);  // Ensure return_coin is consumed
    }

    /// Register forest fire and burn all stakes
    public entry fun register_forest_fire(
        pool: &mut StakingPool,
        _oracle_signature: vector<u8>,
        ctx: &mut TxContext
    ) {
        // Here should be oracle signature verification
        assert!(tx_context::sender(ctx) == pool.oracle_address, E_UNAUTHORIZED);
        
        pool.is_active = false;
        // All staked tokens are burned
    }

    /// Calculate bonus multiplier based on stake amount
    fun calculate_bonus_multiplier(amount: u64): u64 {
        if (amount >= 1000) {
            120 // +20% bonus
        } else if (amount >= 500) {
            110 // +10% bonus
        } else {
            100 // no bonus
        }
    }

    /// Early unstake with fee
    public entry fun early_unstake(
        pool: &mut StakingPool,
        stake_token: &mut StakeToken,
        ctx: &mut TxContext
    ) {
        assert!(pool.is_active, E_POOL_INACTIVE);
        assert!(stake_token.owner == tx_context::sender(ctx), E_UNAUTHORIZED);

        let fee_amount = (stake_token.amount * pool.early_unstake_fee) / PRECISION;
        let return_amount = stake_token.amount - fee_amount;

        let return_coin = coin::from_balance(
            balance::split(&mut pool.total_staked, return_amount),
            ctx
        );

        // Transfer the return_coin to the stake token owner
        sui::transfer::public_transfer(return_coin, stake_token.owner);  // Ensure return_coin is consumed
    }
}
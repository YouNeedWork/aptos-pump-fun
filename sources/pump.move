module pump::pump {
    use std::option;
    use std::signer::address_of;
    use std::string::String;
    use aptos_std::math64;
    use aptos_std::table;
    use aptos_std::table::Table;
    use aptos_std::type_info::type_name;
    use aptos_framework::aptos_coin::AptosCoin;
    use aptos_framework::coin;
    use aptos_framework::coin::{Coin, MintCapability};

    const ERROR_NO_AUTH: u64 = 10000;
    const ERROR_INITIALIZED: u64 = 10001;
    const ERROR_NOT_ALLOW_PRE_MINT: u64 = 10002;
    const ERROR_ALREADY_PUMP: u64 = 10003;
    const ERROR_PUMP_NOT_EXIST: u64 = 10004;
    const ERROR_PUMP_COMPLETED: u64 = 10005;
    const ERROR_PUMP_AMOUNT_IS_NULL: u64 = 10006;

    /*
        real_sui_reserves: 0x2::coin::zero<0x2::sui::SUI>(arg10),
        real_token_reserves: 0x2::coin::mint<T0>(&mut arg1, arg0.initial_virtual_token_reserves - arg0.remain_token_reserves, arg10),
        virtual_token_reserves: arg0.initial_virtual_token_reserves,
        virtual_sui_reserves: arg0.initial_virtual_sui_reserves,
        remain_token_reserves: 0x2::coin::mint<T0>(&mut arg1, arg0.remain_token_reserves, arg10),
        is_completed: false,
    */

    struct PumpConfig has key, store {
        initial_virtual_token_reserves: u64,
        initial_virtual_apt_reserves: u64
    }

    struct Pump<phantom CoinType> has key, store {
        pools: Table<String, Pool<CoinType>>
    }

    struct Pool<phantom CoinType> has key, store {
        real_token_reserves: Coin<CoinType>,
        real_apt_reserves: Coin<AptosCoin>,
        virtual_token_reserves: u64,
        virtual_apt_reserves: u64,
        remain_token_reserves: Coin<CoinType>,
        is_completed: bool,
        dev: address
    }

    fun calculate_add_liquidity_cost(
        apt_reserves: u256, token_reserves: u256, virtual_token_reserves: u256
    ): u256 {
        let reserve_diff = token_reserves - virtual_token_reserves;
        assert!(reserve_diff > 0, 100);
        ((apt_reserves * token_reserves) / reserve_diff) - apt_reserves
    }

    fun calculate_remove_liquidity_return(
        token_reserves: u256, apt_reserves: u256, liquidity_removed: u256
    ): u256 {
        token_reserves
            - ((token_reserves * liquidity_removed) / (liquidity_removed + apt_reserves))
    }

    fun calculate_token_amount_received(
        apt_reserves: u256, token_reserves: u256, liquidity_removed: u256
    ): u256 {
        token_reserves
            - ((apt_reserves * token_reserves) / (apt_reserves + liquidity_removed))
    }

    // initialize
    fun init_module(admin: &signer) {
        initialize(admin);
    }

    public fun initialize(pump_admin: &signer) {
        assert!(address_of(pump_admin) == @pump, ERROR_NO_AUTH);
        assert!(!exists<PumpConfig>(address_of(pump_admin)), ERROR_INITIALIZED);

        move_to(
            pump_admin,
            PumpConfig {
                initial_virtual_token_reserves: 1000000000000 * 100_000_000,
                initial_virtual_apt_reserves: 100 * 100_000_000
            }
        );

        move_to(
            pump_admin,
            Pump {
                pools: table::new<String, Pool<AptosCoin>>()
            }
        );
    }

    public fun deploy<CoinType>(
        caller: &signer, mintCap: MintCapability<CoinType>
    ) acquires Pump, PumpConfig {
        if (*option::borrow(&coin::supply<CoinType>()) != 0) {
            abort ERROR_NOT_ALLOW_PRE_MINT
        };

        let config = borrow_global<PumpConfig>(@pump);

        let sender = address_of(caller);
        let deploy_coin =
            coin::mint<CoinType>(config.initial_virtual_token_reserves, &mintCap);
        coin::destroy_mint_cap(mintCap);
        let coin_type = type_name<CoinType>();
        let pump = borrow_global_mut<Pump<CoinType>>(@pump);
        assert!(table::contains(&pump.pools, coin_type), ERROR_ALREADY_PUMP);

        let pool = Pool {
            real_token_reserves: coin::zero<CoinType>(),
            real_apt_reserves: coin::zero<AptosCoin>(),
            virtual_token_reserves: config.initial_virtual_token_reserves,
            virtual_apt_reserves: config.initial_virtual_apt_reserves,
            remain_token_reserves: deploy_coin,
            is_completed: false,
            dev: sender
        };
        table::add(&mut pump.pools, coin_type, pool);

        //TODO emit event here
    }

    fun swap<CoinType>(
        pool: &mut Pool<CoinType>,
        token: Coin<CoinType>,
        apt: Coin<AptosCoin>,
        token_amount: u64,
        apt_amount: u64
    ): (Coin<CoinType>, Coin<AptosCoin>) {
        assert!(
            coin::value(&token) > 0 || coin::value<AptosCoin>(&apt) > 0,
            ERROR_PUMP_AMOUNT_IS_NULL
        );
        if (coin::value<CoinType>(&token) > 0) {
            pool.virtual_token_reserves = pool.virtual_token_reserves - token_amount;
        };
        if (coin::value<AptosCoin>(&apt) > 0) {
            pool.virtual_apt_reserves = pool.virtual_apt_reserves - apt_amount;
        };

        pool.virtual_token_reserves = pool.virtual_token_reserves
            + coin::value<CoinType>(&token);
        pool.virtual_apt_reserves = pool.virtual_apt_reserves
            + coin::value<AptosCoin>(&apt);

        assert_lp_value_is_increased_or_not_changed(
            pool.virtual_token_reserves,
            pool.virtual_apt_reserves,
            pool.virtual_token_reserves,
            pool.virtual_apt_reserves
        );
        coin::merge<CoinType>(&mut pool.real_token_reserves, token);
        coin::merge<AptosCoin>(&mut pool.real_apt_reserves, apt);

        (
            coin::extract(&mut pool.real_token_reserves, token_amount),
            coin::extract<AptosCoin>(&mut pool.real_apt_reserves, apt_amount)
        )
    }

    fun assert_lp_value_is_increased_or_not_changed(
        arg0: u64, arg1: u64, arg2: u64, arg3: u64
    ) {
        assert!((arg0 as u128) * (arg1 as u128) <= (arg2 as u128) * (arg3 as u128), 2);
    }

    public fun buy<CoinType>(
        caller: &signer, apt_coin: Coin<AptosCoin>, out_amount: u64
    ) acquires Pump {
        let sender = address_of(caller);
        let coin_type = type_name<CoinType>();
        let pump = borrow_global_mut<Pump<CoinType>>(@pump);
        assert!(!table::contains(&pump.pools, coin_type), ERROR_PUMP_NOT_EXIST);
        let pool = table::borrow_mut(&mut pump.pools, coin_type);
        assert!(!pool.is_completed, ERROR_PUMP_COMPLETED);
        let apt_amount = coin::value(&apt_coin);
        //assert!(out_amount > 0, ERROR_PUMP_AMOUNT_TO_LOW);

        let token_reserve_difference =
            pool.virtual_token_reserves - coin::value(&pool.remain_token_reserves);
        let token_amount = math64::min(out_amount, token_reserve_difference);

        let liquidity_cost =
            calculate_add_liquidity_cost(
                (pool.virtual_apt_reserves as u256),
                (pool.virtual_token_reserves as u256),
                (token_amount as u256)
            ) + 1;
        /*
        let platform_fee = 0x92fecee99603c0628ced2fbd37f85c05f6c0049c183eb6b1b58db24764c6c7bc::utils::as_u64(
        0x92fecee99603c0628ced2fbd37f85c05f6c0049c183eb6b1b58db24764c6c7bc::utils::div(
        0x92fecee99603c0628ced2fbd37f85c05f6c0049c183eb6b1b58db24764c6c7bc::utils::mul(
        0x92fecee99603c0628ced2fbd37f85c05f6c0049c183eb6b1b58db24764c6c7bc::utils::from_u64(liquidity_cost),
        0x92fecee99603c0628ced2fbd37f85c05f6c0049c183eb6b1b58db24764c6c7bc::utils::from_u64(arg0.platform_fee)
        ),
        0x92fecee99603c0628ced2fbd37f85c05f6c0049c183eb6b1b58db24764c6c7bc::utils::from_u64(10000)
        )
        );
        assert!(apt_amount >= liquidity_cost + platform_fee, 6);
        */

        let (received_token, remaining_apt) =
            swap<CoinType>(
                pool,
                coin::zero<CoinType>(),
                apt_coin,
                token_amount,
                apt_amount - (liquidity_cost as u64)
            );
        pool.virtual_token_reserves = pool.virtual_token_reserves
            - coin::value(&received_token);

        coin::deposit(sender, received_token);
        coin::deposit(sender, remaining_apt);
        /*
        let admin_address = arg0.admin;
        0x2::transfer::public_transfer<0x2::coin::Coin<0x2::sui::SUI>>(0x2::coin::split<0x2::sui::SUI>(&mut arg1, platform_fee, arg5), admin_address);

        if (token_reserve_difference == token_amount || 0x2::coin::value<0x2::sui::SUI>(&pool.real_sui_reserves) >= 6000000000000) {
        transfer_pool<T0>(pool, arg2, admin_address, arg0.graduated_fee, arg4, arg5);
        };
        */
    }

    public fun sell<CoinType>(
        caller: &signer, token: Coin<CoinType>, out_amount: u64
    ) acquires Pump {
        let sender = address_of(caller);
        let coin_type = type_name<CoinType>();
        let pump = borrow_global_mut<Pump<CoinType>>(@pump);
        assert!(!table::contains(&pump.pools, coin_type), ERROR_PUMP_NOT_EXIST);
        let pool = table::borrow_mut(&mut pump.pools, coin_type);
        assert!(!pool.is_completed, ERROR_PUMP_COMPLETED);
        let token_amount = coin::value<CoinType>(&token);
        //assert!(token_amount > 0, 2);

        let liquidity_remove =
            calculate_remove_liquidity_return(
                (pool.virtual_token_reserves as u256),
                (pool.virtual_apt_reserves as u256),
                (token_amount as u256)
            );

        let out_amount = math64::min(out_amount, (liquidity_remove as u64));
        let (token, apt) =
            swap<CoinType>(pool, token, coin::zero<AptosCoin>(), 0, out_amount);

        pool.virtual_apt_reserves = pool.virtual_apt_reserves
            - coin::value<AptosCoin>(&apt);
        coin::deposit(sender, token);
        coin::deposit(sender, apt);
    }
}

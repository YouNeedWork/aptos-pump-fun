module pump::pump {
    use std::option;
    use std::signer::address_of;
    use std::string;
    use std::string::String;
    use std::vector;
    use aptos_std::math64;
    use aptos_std::type_info::type_name;
    use aptos_framework::account;
    use aptos_framework::account::SignerCapability;
    use aptos_framework::aptos_coin::AptosCoin;
    use aptos_framework::coin;
    use aptos_framework::coin::Coin;
    use aptos_framework::event;

    use razor::RazorSwapPool;
    use razor::RazorPoolLibrary;

    //use liquidswap::router;

    //errors
    const ERROR_INVALID_LENGTH: u64 = 9999;
    const ERROR_NO_AUTH: u64 = 10000;
    const ERROR_INITIALIZED: u64 = 10001;
    const ERROR_NOT_ALLOW_PRE_MINT: u64 = 10002;
    const ERROR_ALREADY_PUMP: u64 = 10003;
    const ERROR_PUMP_NOT_EXIST: u64 = 10004;
    const ERROR_PUMP_COMPLETED: u64 = 10005;
    const ERROR_PUMP_AMOUNT_IS_NULL: u64 = 10006;
    const ERROR_PUMP_AMOUNT_TO_LOW: u64 = 10007;
    const ERROR_TOKEN_DECIMAL: u64 = 10008;

    // structs
    struct PumpConfig has key, store {
        platform_fee: u64,
        resource_cap: SignerCapability,
        platform_fee_address: address,
        initial_virtual_token_reserves: u64,
        initial_virtual_apt_reserves: u64,
        remain_token_reserves: u64,
        token_decimals: u8
    }

    struct Pool<phantom CoinType> has key, store {
        real_token_reserves: Coin<CoinType>,
        real_apt_reserves: Coin<AptosCoin>,
        virtual_token_reserves: u64,
        virtual_apt_reserves: u64,
        remain_token_reserves: Coin<CoinType>,
        token_freeze_cap: coin::FreezeCapability<CoinType>,
        is_completed: bool,
        dev: address
    }

    struct Handle has key {
        created_events: event::EventHandle<PumpEvent>,
        trade_events: event::EventHandle<TradeEvent>,
        transfer_events: event::EventHandle<TransferEvent>,
        unfreeze_events: event::EventHandle<UnfreezeEvent>
    }

    // events
    #[event]
    struct PumpEvent has drop, store {
        pool: String,
        dev: address,
        description: String,
        name: String,
        symbol: String,
        uri: String,
        website: String,
        telegram: String,
        twitter: String,
        //ts:u64,
        platform_fee: u64,
        initial_virtual_token_reserves: u64,
        initial_virtual_apt_reserves: u64,
        remain_token_reserves: u64,
        token_decimals: u8
    }

    #[event]
    struct TradeEvent has drop, store {
        apt_amount: u64,
        is_buy: bool,
        token_address: String,
        token_amount: u64,
        //ts: u64,
        user: address,
        virtual_aptos_reserves: u64,
        virtual_token_reserves: u64
    }

    #[event]
    struct TransferEvent has drop, store {
        apt_amount: u64,
        token_address: String,
        token_amount: u64,
        user: address,
        virtual_aptos_reserves: u64,
        virtual_token_reserves: u64
    }

    #[event]
    struct UnfreezeEvent has drop, store {
        token_address: String,
        user: address
    }

    #[view]
    public fun buy_price<CoinType>(buy_token_amount: u64): u64 acquires PumpConfig, Pool {
        let config = borrow_global<PumpConfig>(@pump);

        let resource = account::create_signer_with_capability(&config.resource_cap);
        let resorce_addr = address_of(&resource);
        assert!(exists<Pool<CoinType>>(resorce_addr), ERROR_PUMP_NOT_EXIST);

        let pool = borrow_global_mut<Pool<CoinType>>(resorce_addr);
        assert!(!pool.is_completed, ERROR_PUMP_COMPLETED);

        let token_reserve_difference =
            pool.virtual_token_reserves - coin::value(&pool.remain_token_reserves);

        let token_amount = math64::min(buy_token_amount, token_reserve_difference);

        let liquidity_cost =
            calculate_add_liquidity_cost(
                (pool.virtual_apt_reserves as u256),
                (pool.virtual_token_reserves as u256),
                (token_amount as u256)
            ) + 1;

        (liquidity_cost as u64)
    }

    #[view]
    public fun sell_price<CoinType>(sell_token_amount: u64): u64 acquires PumpConfig, Pool {
        let config = borrow_global<PumpConfig>(@pump);

        let resource = account::create_signer_with_capability(&config.resource_cap);
        let resorce_addr = address_of(&resource);
        assert!(exists<Pool<CoinType>>(resorce_addr), ERROR_PUMP_NOT_EXIST);
        let pool = borrow_global_mut<Pool<CoinType>>(resorce_addr);
        assert!(!pool.is_completed, ERROR_PUMP_COMPLETED);

        let liquidity_remove =
            calculate_remove_liquidity_return(
                (pool.virtual_token_reserves as u256),
                (pool.virtual_apt_reserves as u256),
                (sell_token_amount as u256)
            );

        (liquidity_remove as u64)
    }

    #[view]
    public fun calculate_add_liquidity_cost(
        apt_reserves: u256, virtual_token_reserves: u256, token_amount: u256
    ): u256 {
        let reserve_diff = virtual_token_reserves - token_amount;
        assert!(reserve_diff > 0, 100);

        ((apt_reserves * virtual_token_reserves) / reserve_diff) - apt_reserves
    }

    #[view]
    public fun calculate_remove_liquidity_return(
        token_reserves: u256, apt_reserves: u256, liquidity_removed: u256
    ): u256 {
        apt_reserves
            - ((token_reserves * apt_reserves) / (liquidity_removed + token_reserves))
    }

    #[view]
    public fun calculate_token_amount_received(
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

        let (_, signer_cap) = account::create_resource_account(pump_admin, b"pump");

        move_to(
            pump_admin,
            Handle {
                created_events: account::new_event_handle<PumpEvent>(pump_admin),
                trade_events: account::new_event_handle<TradeEvent>(pump_admin),
                transfer_events: account::new_event_handle<TransferEvent>(pump_admin),
                unfreeze_events: account::new_event_handle<UnfreezeEvent>(pump_admin)
            }
        );

        move_to(
            pump_admin,
            PumpConfig {
                platform_fee: 50,
                platform_fee_address: @pump,
                resource_cap: signer_cap,
                initial_virtual_token_reserves: 10000000000000000,
                initial_virtual_apt_reserves: 30 * 1_000_000_000, //30 APT
                token_decimals: 6,
                remain_token_reserves: 2000000000000000
            }
        );
    }

    entry public fun deploy<CoinType>(
        caller: &signer,
        description: String,
        name: String,
        symbol: String,
        uri: String,
        website: String,
        telegram: String,
        twitter: String
    ) acquires PumpConfig, Handle {
        assert!(!(string::length(&description) > 1000), ERROR_INVALID_LENGTH);
        assert!(!(string::length(&name) > 100), ERROR_INVALID_LENGTH);
        assert!(!(string::length(&symbol) > 100), ERROR_INVALID_LENGTH);
        assert!(!(string::length(&uri) > 100), ERROR_INVALID_LENGTH);
        assert!(!(string::length(&website) > 100), ERROR_INVALID_LENGTH);
        assert!(!(string::length(&telegram) > 100), ERROR_INVALID_LENGTH);
        assert!(!(string::length(&twitter) > 100), ERROR_INVALID_LENGTH);
        let config = borrow_global<PumpConfig>(@pump);
        let resource = account::create_signer_with_capability(&config.resource_cap);
        let resorce_addr = address_of(&resource);
        assert!(!exists<Pool<CoinType>>(resorce_addr), ERROR_PUMP_NOT_EXIST);

        let (burn_cap, freeze_cap, mintCap) =
            coin::initialize<CoinType>(
                caller,
                name,
                symbol,
                config.token_decimals,
                true
            );

        coin::destroy_burn_cap(burn_cap);

        let sender = address_of(caller);

        let pool = Pool {
            real_token_reserves: coin::mint<CoinType>(
                config.initial_virtual_token_reserves - config.remain_token_reserves,
                &mintCap
            ),
            real_apt_reserves: coin::zero<AptosCoin>(),
            virtual_token_reserves: config.initial_virtual_token_reserves,
            virtual_apt_reserves: config.initial_virtual_apt_reserves,
            remain_token_reserves: coin::mint<CoinType>(
                config.remain_token_reserves, &mintCap
            ),
            token_freeze_cap: freeze_cap,
            is_completed: false,
            dev: sender
        };

        let resource = account::create_signer_with_capability(&config.resource_cap);
        coin::register<CoinType>(&resource);
        move_to(&resource, pool);

        coin::destroy_mint_cap(mintCap);

        event::emit_event(
            &mut borrow_global_mut<Handle>(@pump).created_events,
            PumpEvent {
                platform_fee: config.platform_fee,
                initial_virtual_token_reserves: config.initial_virtual_token_reserves,
                initial_virtual_apt_reserves: config.initial_virtual_apt_reserves,
                remain_token_reserves: config.remain_token_reserves,
                token_decimals: config.token_decimals,
                pool: type_name<Pool<CoinType>>(),
                dev: sender,
                description,
                name,
                symbol,
                uri,
                website,
                telegram,
                twitter
            }
        );
    }

    entry public fun deploy_and_buy<CoinType>(
        caller: &signer,
        out_amount: u64,
        description: String,
        name: String,
        symbol: String,
        uri: String,
        website: String,
        telegram: String,
        twitter: String
    ) acquires PumpConfig, Pool, Handle {
        assert!(!(string::length(&description) > 300), ERROR_INVALID_LENGTH);
        assert!(!(string::length(&name) > 100), ERROR_INVALID_LENGTH);
        assert!(!(string::length(&symbol) > 100), ERROR_INVALID_LENGTH);
        assert!(!(string::length(&uri) > 100), ERROR_INVALID_LENGTH);
        assert!(!(string::length(&website) > 100), ERROR_INVALID_LENGTH);
        assert!(!(string::length(&telegram) > 100), ERROR_INVALID_LENGTH);
        assert!(!(string::length(&twitter) > 100), ERROR_INVALID_LENGTH);

        let config = borrow_global<PumpConfig>(@pump);
        let sender = address_of(caller);

        let resource = account::create_signer_with_capability(&config.resource_cap);
        let resorce_addr = address_of(&resource);
        assert!(!exists<Pool<CoinType>>(resorce_addr), ERROR_PUMP_NOT_EXIST);

        let (burn_cap, freeze_cap, mintCap) =
            coin::initialize<CoinType>(
                caller,
                name,
                symbol,
                config.token_decimals,
                true
            );

        coin::destroy_burn_cap(burn_cap);
        coin::destroy_freeze_cap(freeze_cap);

        let pool = Pool {
            real_token_reserves: coin::mint<CoinType>(
                config.initial_virtual_token_reserves - config.remain_token_reserves,
                &mintCap
            ),
            real_apt_reserves: coin::zero<AptosCoin>(),
            virtual_token_reserves: config.initial_virtual_token_reserves,
            virtual_apt_reserves: config.initial_virtual_apt_reserves,
            remain_token_reserves: coin::mint<CoinType>(
                config.remain_token_reserves, &mintCap
            ),
            token_freeze_cap: freeze_cap,
            is_completed: false,
            dev: sender
        };

        let resource = account::create_signer_with_capability(&config.resource_cap);
        coin::register<CoinType>(&resource);
        move_to(&resource, pool);

        coin::destroy_mint_cap(mintCap);

        event::emit_event(
            &mut borrow_global_mut<Handle>(@pump).created_events,
            PumpEvent {
                platform_fee: config.platform_fee,
                initial_virtual_token_reserves: config.initial_virtual_token_reserves,
                initial_virtual_apt_reserves: config.initial_virtual_apt_reserves,
                remain_token_reserves: config.remain_token_reserves,
                token_decimals: config.token_decimals,
                pool: type_name<Pool<CoinType>>(),
                dev: sender,
                description,
                name,
                symbol,
                uri,
                website,
                telegram,
                twitter
            }
        );

        buy<CoinType>(caller, out_amount);
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
            coin::extract<CoinType>(&mut pool.real_token_reserves, token_amount),
            coin::extract<AptosCoin>(&mut pool.real_apt_reserves, apt_amount)
        )
    }

    fun assert_lp_value_is_increased_or_not_changed(
        arg0: u64, arg1: u64, arg2: u64, arg3: u64
    ) {
        assert!((arg0 as u128) * (arg1 as u128) <= (arg2 as u128) * (arg3 as u128), 2);
    }

    public entry fun buy<CoinType>(
        caller: &signer, buy_token_amount: u64
    ) acquires PumpConfig, Pool, Handle {
        assert!(buy_token_amount > 0, ERROR_PUMP_AMOUNT_IS_NULL);

        let sender = address_of(caller);
        let config = borrow_global<PumpConfig>(@pump);

        let resource = account::create_signer_with_capability(&config.resource_cap);
        let resource_addr = address_of(&resource);
        assert!(exists<Pool<CoinType>>(resource_addr), ERROR_PUMP_NOT_EXIST);

        let pool = borrow_global_mut<Pool<CoinType>>(resource_addr);
        assert!(!pool.is_completed, ERROR_PUMP_COMPLETED);

        let token_reserve_difference =
            pool.virtual_token_reserves - coin::value(&pool.remain_token_reserves);

        let token_amount = math64::min(buy_token_amount, token_reserve_difference);

        let liquidity_cost =
            calculate_add_liquidity_cost(
                (pool.virtual_apt_reserves as u256),
                (pool.virtual_token_reserves as u256),
                (token_amount as u256)
            ) + 1;

        let apt_coin = coin::withdraw<AptosCoin>(caller, (liquidity_cost as u64));

        let platform_fee =
            math64::mul_div((liquidity_cost as u64), config.platform_fee, 10000);
        let platform_fee_coin = coin::withdraw<AptosCoin>(caller, platform_fee);

        let (received_token, remaining_apt) =
            swap<CoinType>(
                pool,
                coin::zero<CoinType>(),
                apt_coin,
                token_amount,
                0
            );

        pool.virtual_token_reserves = pool.virtual_token_reserves
            - coin::value(&received_token);

        let token_amount = coin::value(&received_token);
        let apt_amount = coin::value(&remaining_apt);

        coin::register<CoinType>(caller);
        coin::register<AptosCoin>(caller);

        coin::deposit(sender, received_token);
        coin::freeze_coin_store(sender, &pool.token_freeze_cap);

        coin::deposit(sender, remaining_apt);
        coin::deposit(config.platform_fee_address, platform_fee_coin);

        if (token_reserve_difference == token_amount
            || coin::value<AptosCoin>(&pool.real_apt_reserves) >= 3_000_000_000) {
            // TODO: transfer_pool to dex: https://app.razordex.xyz/
            pool.is_completed = true;
            coin::unfreeze_coin_store(sender, &pool.token_freeze_cap);

            let received_token = coin::extract_all(&mut pool.real_token_reserves);
            let received_apt = coin::extract_all(&mut pool.real_apt_reserves);

            let received_token_amount = coin::value(&received_token);
            let received_apt_amount = coin::value(&received_apt);

            coin::deposit(resource_addr, received_token);
            coin::deposit(resource_addr, received_apt);

            if (RazorPoolLibrary::compare<CoinType, AptosCoin>()) {
                RazorSwapPool::add_liquidity_entry<CoinType, AptosCoin>(
                    caller,
                    received_token_amount,
                    received_apt_amount,
                    0,
                    0
                );

                let sup =
                    option::extract(
                        &mut coin::supply<RazorSwapPool::LPCoin<CoinType, AptosCoin>>()
                    );

                let co =
                    coin::withdraw<RazorSwapPool::LPCoin<CoinType, AptosCoin>>(
                        &mut resource, (sup as u64)
                    );
                coin::deposit(@dead, co);
            } else {
                RazorSwapPool::add_liquidity_entry<AptosCoin, CoinType>(
                    caller,
                    received_apt_amount,
                    received_token_amount,
                    0,
                    0
                );

                let sup =
                    option::extract(
                        &mut coin::supply<RazorSwapPool::LPCoin<AptosCoin, CoinType>>()
                    );

                let co =
                    coin::withdraw<RazorSwapPool::LPCoin<AptosCoin, CoinType>>(
                        &mut resource, (sup as u64)
                    );
                coin::deposit(@dead, co);
            };

            event::emit_event(
                &mut borrow_global_mut<Handle>(@pump).transfer_events,
                TransferEvent {
                    apt_amount,
                    token_address: type_name<Coin<CoinType>>(),
                    token_amount,
                    user: sender,
                    virtual_aptos_reserves: pool.virtual_apt_reserves,
                    virtual_token_reserves: pool.virtual_token_reserves
                }
            );
            /*
            router::register_pool<AptosCoin, CoinType, Curve>(caller);
            let (apt,token,lp) = router::add_liquidity<AptosCoin, CoinType, Curve>(
                coin_x: Coin<X>,
                min_coin_x_val: u64,
                coin_y: Coin<Y>,
                min_coin_y_val: u64,
            );
            //Send to the 0x000000 address
            coin::deposit(sender, lp);
            coin::deposit(sender, apt);
            coin::deposit(sender, token);
            */
        };

        event::emit_event(
            &mut borrow_global_mut<Handle>(@pump).trade_events,
            TradeEvent {
                apt_amount,
                is_buy: true,
                token_address: type_name<Coin<CoinType>>(),
                token_amount,
                //ts: timestamp::now_seconds(),
                user: sender,
                virtual_aptos_reserves: pool.virtual_apt_reserves,
                virtual_token_reserves: pool.virtual_token_reserves
            }
        );
    }

    public entry fun sell<CoinType>(
        caller: &signer, sell_token_amount: u64
    ) acquires PumpConfig, Pool, Handle {
        assert!(sell_token_amount > 0, ERROR_PUMP_AMOUNT_IS_NULL);

        let sender = address_of(caller);
        let config = borrow_global<PumpConfig>(@pump);

        let resource = account::create_signer_with_capability(&config.resource_cap);
        let resorce_addr = address_of(&resource);
        assert!(exists<Pool<CoinType>>(resorce_addr), ERROR_PUMP_NOT_EXIST);
        let pool = borrow_global_mut<Pool<CoinType>>(resorce_addr);
        assert!(!pool.is_completed, ERROR_PUMP_COMPLETED);

        let liquidity_remove =
            calculate_remove_liquidity_return(
                (pool.virtual_token_reserves as u256),
                (pool.virtual_apt_reserves as u256),
                (sell_token_amount as u256)
            );

        coin::unfreeze_coin_store(sender, &pool.token_freeze_cap);
        let out_coin = coin::withdraw<CoinType>(caller, sell_token_amount);
        let (token, apt) =
            swap<CoinType>(
                pool,
                out_coin,
                coin::zero<AptosCoin>(),
                0,
                (liquidity_remove as u64)
            );

        pool.virtual_apt_reserves = pool.virtual_apt_reserves
            - coin::value<AptosCoin>(&apt);

        let apt_amount = coin::value(&apt);
        let platform_fee = math64::mul_div(apt_amount, config.platform_fee, 10000);
        let platform_fee_coin = coin::extract<AptosCoin>(&mut apt, platform_fee);

        coin::deposit(config.platform_fee_address, platform_fee_coin);
        coin::deposit(sender, token);
        coin::deposit(sender, apt);

        event::emit_event(
            &mut borrow_global_mut<Handle>(@pump).trade_events,
            TradeEvent {
                apt_amount,
                is_buy: false,
                token_address: type_name<Coin<CoinType>>(),
                token_amount: sell_token_amount,
                //ts: timestamp::now_seconds(),
                user: sender,
                virtual_aptos_reserves: pool.virtual_apt_reserves,
                virtual_token_reserves: pool.virtual_token_reserves
            }
        );
    }

    public entry fun unfreeze_token<CoinType>(caller: &signer) acquires PumpConfig, Pool, Handle {
        let sender = address_of(caller);
        let config = borrow_global<PumpConfig>(@pump);
        let resource = account::create_signer_with_capability(&config.resource_cap);
        let resorce_addr = address_of(&resource);
        assert!(exists<Pool<CoinType>>(resorce_addr), ERROR_PUMP_NOT_EXIST);
        let pool = borrow_global_mut<Pool<CoinType>>(resorce_addr);

        //require completed here.
        assert!(pool.is_completed, ERROR_PUMP_COMPLETED);
        coin::unfreeze_coin_store(sender, &pool.token_freeze_cap);
        //emit unfreeze event
        event::emit_event(
            &mut borrow_global_mut<Handle>(@pump).unfreeze_events,
            UnfreezeEvent {
                token_address: type_name<Coin<CoinType>>(),
                user: sender
            }
        );
    }

    public entry fun batch_unfreeze_token<CoinType>(
        caller: &signer, addresses: vector<address>
    ) acquires PumpConfig, Pool, Handle {
        let sender = address_of(caller);
        let config = borrow_global<PumpConfig>(@pump);
        let resource = account::create_signer_with_capability(&config.resource_cap);
        let resorce_addr = address_of(&resource);
        assert!(exists<Pool<CoinType>>(resorce_addr), ERROR_PUMP_NOT_EXIST);
        let pool = borrow_global_mut<Pool<CoinType>>(resorce_addr);

        //require completed here.
        assert!(pool.is_completed, ERROR_PUMP_COMPLETED);

        let len = vector::length(&addresses);
        while (len >= 1) {
            let addr = vector::pop_back(&mut addresses);
            coin::unfreeze_coin_store(addr, &pool.token_freeze_cap);
            event::emit_event(
                &mut borrow_global_mut<Handle>(@pump).unfreeze_events,
                UnfreezeEvent {
                    token_address: type_name<Coin<CoinType>>(),
                    user: sender
                }
            );

            len = len - 1;
        }
    }

    // tests
    #[test_only]
    use std::signer;
    #[test_only]
    use aptos_std::debug::print;
    #[test_only]
    use aptos_framework::aptos_coin;

    #[test_only]
    public fun init_module_for_test(creator: &signer) {
        init_module(creator);
    }

    #[test_only]
    struct USDT has key, store {}

    #[test_only]
    public fun deploy_usdt(pump: &signer) acquires PumpConfig, Handle {
        let source_addr = signer::address_of(pump);
        account::create_account_for_test(source_addr);
        init_module_for_test(pump);
        deploy<USDT>(
            pump,
            string::utf8(b""),
            string::utf8(b""),
            string::utf8(b""),
            string::utf8(b""),
            string::utf8(b""),
            string::utf8(b""),
            string::utf8(b"")
        );
    }

    #[test(pump = @pump)]
    public fun test_deploy(pump: &signer) acquires PumpConfig, Handle {
        deploy_usdt(pump);
    }

    #[test_only]
    public fun new_account(account_addr: address): signer {
        if (!account::exists_at(account_addr)) {
            account::create_account_for_test(account_addr)
        } else {
            let cap = account::create_test_signer_cap(account_addr);
            account::create_signer_with_capability(&cap)
        }
    }

    #[test_only]
    public fun new_test_account(account_addr: address): signer {
        if (!account::exists_at(account_addr)) {
            account::create_account_for_test(account_addr)
        } else {
            let cap = account::create_test_signer_cap(account_addr);
            account::create_signer_with_capability(&cap)
        }
    }

    #[test(pump = @pump)]
    public fun test_init(pump: &signer) acquires PumpConfig {
        init_module_for_test(pump);
        let pump = borrow_global<PumpConfig>(@pump);
        assert!(pump.platform_fee == 50, 1);
        assert!(pump.platform_fee_address == @pump, 2);
        assert!(pump.initial_virtual_token_reserves == 10000000000000000, 3);
        assert!(pump.initial_virtual_apt_reserves == 30 * 1_000_000_000, 4);
        assert!(pump.remain_token_reserves == 2000000000000000, 5);
        assert!(pump.token_decimals == 6, 6);
    }

    #[test(pump = @pump)]
    public fun test_buy(pump: &signer) acquires PumpConfig, Pool, Handle {
        deploy_usdt(pump);

        let source_addr = signer::address_of(pump);
        account::create_account_for_test(source_addr);

        let aptos_framework = new_test_account(@aptos_framework);
        let (burn_cap, mint_cap) = aptos_coin::initialize_for_test(&aptos_framework);
        //let apt_coin = coin::mint<AptosCoin>(100_000_000_000, &mint_cap);
        coin::register<AptosCoin>(pump);
        //aptos_coin::mint(&aptos_framework,@pump, 100_000_000_000);
        let apt_coin = coin::mint(100_000_000_000, &mint_cap);
        coin::deposit(@pump, apt_coin);

        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);
        // Perform a buy transaction
        buy<USDT>(pump, 500_000_000_000);

        let config = borrow_global<PumpConfig>(@pump);
        let resource = account::create_signer_with_capability(&config.resource_cap);
        let pool = borrow_global_mut<Pool<USDT>>(address_of(&resource));

        print(&coin::value(&pool.real_apt_reserves));

        assert!(pool.virtual_token_reserves < config.initial_virtual_token_reserves, 1);
        assert!(coin::value(&pool.real_apt_reserves) > 0, 2);
        assert!(coin::value(&pool.real_apt_reserves) == 1500076, 2);
    }

    #[test(pump = @pump)]
    public fun test_sell(pump: &signer) acquires PumpConfig, Pool, Handle {
        deploy_usdt(pump);

        let aptos_framework = new_test_account(@aptos_framework);
        let (burn_cap, mint_cap) = aptos_coin::initialize_for_test(&aptos_framework);
        coin::register<AptosCoin>(pump);
        let apt_coin = coin::mint(100_000_000_000, &mint_cap);
        coin::deposit(@pump, apt_coin);
        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);

        // Perform a buy transaction
        buy<USDT>(pump, 500_000_000_000);
        sell<USDT>(pump, 500_000_000_000); // give a amount that is greater than the amount of token in the pool

        let pump = borrow_global<PumpConfig>(@pump);
        assert!(pump.platform_fee == 50, 1);
        assert!(pump.platform_fee_address == @pump, 2);
        assert!(pump.initial_virtual_token_reserves == 10000000000000000, 3);
        assert!(pump.initial_virtual_apt_reserves == 30 * 1_000_000_000, 4);
        assert!(pump.remain_token_reserves == 2000000000000000, 5);
    }

    #[test(pump = @pump)]
    public fun test_sell_for_min_amount(pump: &signer) acquires PumpConfig, Pool, Handle {
        deploy_usdt(pump);

        let aptos_framework = new_test_account(@aptos_framework);
        let (burn_cap, mint_cap) = aptos_coin::initialize_for_test(&aptos_framework);
        coin::register<AptosCoin>(pump);
        let apt_coin = coin::mint(100_000_000_000, &mint_cap);
        coin::deposit(@pump, apt_coin);
        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);

        // Perform a buy transaction
        buy<USDT>(pump, 1_000_000);
        sell<USDT>(pump, 1_000_000); // give a amount that is greater than the amount of token in the pool

        let pump = borrow_global<PumpConfig>(@pump);
        assert!(pump.platform_fee == 50, 1);
        assert!(pump.platform_fee_address == @pump, 2);
        assert!(pump.initial_virtual_token_reserves == 10000000000000000, 3);
        assert!(pump.initial_virtual_apt_reserves == 30 * 1_000_000_000, 4);
        assert!(pump.remain_token_reserves == 2000000000000000, 5);
    }
}

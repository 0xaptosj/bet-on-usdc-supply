module betting_app_addr::betting_app {
    use std::bcs;
    use std::option;
    use std::signer;
    use aptos_std::string_utils;
    use aptos_framework::aptos_coin::AptosCoin;
    use aptos_framework::coin;

    use aptos_framework::event;
    use aptos_framework::fungible_asset::{Self, FungibleStore, Metadata};
    use aptos_framework::object::{Self, Object, ExtendRef};
    use aptos_framework::primary_fungible_store;
    use aptos_framework::timestamp;

    /// Bet has ended
    const ERR_BET_HAS_ENDED: u64 = 1;
    /// Bet has not ended
    const ERR_BET_HAS_NOT_ENDED: u64 = 2;
    /// Bet has been resolved
    const ERR_BET_HAS_BEEN_RESOLVED: u64 = 3;
    /// Bet has not been resolved
    const ERR_BET_HAS_NOT_BEEN_RESOLVED: u64 = 4;

    const END_OF_FEB_TIMESTAMP: u64 = 1740812400;
    // USDC has 6 decimals so 100m is 100_000_000_000_000
    const ONE_MIL_USDC_SUPPLY: u128 = 100_000_000_000_000;

    struct Bet has copy, drop, key, store {
        result: bool,
        amount: u64,
    }

    struct BetConfig has key, store {
        stake_store: Object<FungibleStore>,
        stake_store_controller: ExtendRef,
        expiration_timestamp: u64,
        yes_bet: u64,
        no_bet: u64,
        // true if yes win (i.e. supply hit 100m by expiration time)
        // false if no win (i.e. supply not hit 100m by expiration time)
        result: bool,
        // whether the bet has been resolved
        resolved: bool,
    }

    #[event]
    struct PlaceBetEvent has drop, store {
        user_addr: address,
        bet: bool,
        amount: u64
    }

    #[event]
    struct ResolveBetEvent has drop, store {
        result: bool,
    }

    #[event]
    struct ClaimRewardEvent has drop, store {
        user_addr: address,
        bet: bool,
        pnl: u64
    }

    // This function is only called once when the module is published for the first time.
    // init_module is optional, you can also have an entry function as the initializer.
    fun init_module(sender: &signer) {
        init_module_internal(sender);
    }

    fun init_module_internal(sender: &signer) {
        let sender_addr = signer::address_of(sender);
        let fungible_store_constructor_ref = &object::create_object(sender_addr);

        move_to(sender, BetConfig {
            stake_store: fungible_asset::create_store(
                fungible_store_constructor_ref,
                object::address_to_object<Metadata>(@apt_fa_addr),
            ),
            stake_store_controller: object::generate_extend_ref(fungible_store_constructor_ref),
            expiration_timestamp: END_OF_FEB_TIMESTAMP,
            yes_bet: 0,
            no_bet: 0,
            result: false,
            resolved: false,
        });
    }

    // ======================== Write functions ========================

    public entry fun place_bet(sender: &signer, bet: bool, amount: u64) acquires BetConfig {
        let bet_config = borrow_global_mut<BetConfig>(@betting_app_addr);
        assert!(bet_config.expiration_timestamp > timestamp::now_seconds() && !bet_config.resolved, ERR_BET_HAS_ENDED);

        let sender_addr = signer::address_of(sender);
        let bet_obj_constructor_ref = &object::create_named_object(
            sender,
            construct_user_bet_object_seed(sender_addr),
        );
        let bet_obj_signer = &object::generate_signer(bet_obj_constructor_ref);
        let message = Bet {
            result: bet,
            amount,
        };
        move_to(bet_obj_signer, message);

        if (bet) {
            bet_config.yes_bet = bet_config.yes_bet + amount;
        } else {
            bet_config.no_bet = bet_config.no_bet + amount;
        };

        convert_apt_coin_to_fa_when_not_enought(sender, amount);
        fungible_asset::transfer(
            sender,
            primary_fungible_store::primary_store(sender_addr, object::address_to_object<Metadata>(@apt_fa_addr)),
            bet_config.stake_store,
            amount,
        );

        event::emit(PlaceBetEvent {
            user_addr: sender_addr,
            bet,
            amount,
        });
    }

    public entry fun resolve_bet(_sender: &signer) acquires BetConfig {
        let bet_config = borrow_global_mut<BetConfig>(@betting_app_addr);
        assert!(bet_config.expiration_timestamp < timestamp::now_seconds(), ERR_BET_HAS_NOT_ENDED);
        assert!(!bet_config.resolved, ERR_BET_HAS_BEEN_RESOLVED);

        let result = *option::borrow_with_default(
            &fungible_asset::supply(object::address_to_object<Metadata>(@usdc_fa_addr)),
            &0
        )
            > ONE_MIL_USDC_SUPPLY;

        bet_config.result = result;
        bet_config.resolved = true;

        event::emit(ResolveBetEvent {
            result,
        });
    }

    public entry fun claim_reward(sender: &signer) acquires BetConfig, Bet {
        let sender_addr = signer::address_of(sender);
        let bet_config = borrow_global<BetConfig>(@betting_app_addr);
        assert!(bet_config.resolved, ERR_BET_HAS_NOT_BEEN_RESOLVED);

        let (bet_result, pnl) = get_pnl_internal(bet_config, sender_addr);
        if (bet_result) {
            fungible_asset::transfer(
                &object::generate_signer_for_extending(&bet_config.stake_store_controller),
                bet_config.stake_store,
                primary_fungible_store::primary_store(sender_addr, object::address_to_object<Metadata>(@apt_fa_addr)),
                pnl
            );
        };

        event::emit(ClaimRewardEvent {
            user_addr: sender_addr,
            bet: bet_result,
            pnl,
        });
    }

    // ======================== Read Functions ========================

    #[view]
    // returns (is_bet_resolved, user_win_or_not, reward or lost)
    public fun get_pnl(user_addr: address): (bool, bool, u64) acquires BetConfig, Bet {
        let bet_config = borrow_global<BetConfig>(@betting_app_addr);
        if (!bet_config.resolved) {
            return (false, false, 0)
        } else {
            let (bet_result, pnl) = get_pnl_internal(bet_config, user_addr);
            return (true, bet_result, pnl)
        }
    }

    // ================================= Helper ================================== //

    fun construct_user_bet_object_seed(user_addr: address): vector<u8> {
        bcs::to_bytes(&string_utils::format2(&b"{}_better_{}", @betting_app_addr, user_addr))
    }

    fun get_pnl_internal(bet_config: &BetConfig, user_addr: address): (bool, u64) acquires Bet {
        let bet = borrow_global<Bet>(object::create_object_address(
            &user_addr,
            construct_user_bet_object_seed(copy user_addr))
        );

        if (bet.result != bet_config.result) {
            return (false, bet.amount)
        };

        let reward = if (bet.result) {
            bet.amount * (bet_config.yes_bet + bet_config.no_bet) / bet_config.yes_bet
        } else {
            bet.amount * (bet_config.yes_bet + bet_config.no_bet) / bet_config.no_bet
        };

        return (true, reward)
    }

    fun convert_apt_coin_to_fa_when_not_enought(sender: &signer, amount: u64) {
        let sender_addr = signer::address_of(sender);
        let apt_fa_metadata = object::address_to_object<Metadata>(@apt_fa_addr);
        if (primary_fungible_store::is_balance_at_least(sender_addr, apt_fa_metadata, amount)) {
            return
        };
        let coin_apt = coin::withdraw<AptosCoin>(sender, amount);
        let fa_apt = coin::coin_to_fungible_asset(coin_apt);
        primary_fungible_store::deposit(sender_addr, fa_apt);
    }

    // ================================= Uint Tests Helper ================================== //

    #[test_only]
    public fun init_module_for_test(aptos_framework: &signer, sender: &signer) {
        timestamp::set_time_has_started_for_testing(aptos_framework);
        init_module(sender);
    }
}

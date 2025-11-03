#[test_only]
module cdp::cdp_multi_price_tests {
    use std::signer;
    use std::string;
    use std::fixed_point32;
    use supra_framework::coin;
    use supra_framework::account;
    use supra_framework::supra_coin::{Self, SupraCoin};
    use cdp::events;
    use supra_framework::block;
    use cdp::cdp_multi::{Self, CASH};
    use supra_framework::timestamp;
    use supra_framework::debug;
    use cdp::price_oracle;

    #[test]
    fun test_price_fetch() {
        // let price = price_oracle::get_price_from_supra_test(0);
        // debug::print(&string::utf8(b"price: "));
        // debug::print(&price);
    }

}
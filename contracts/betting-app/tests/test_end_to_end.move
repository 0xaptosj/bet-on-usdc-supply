#[test_only]
module betting_app_addr::test_end_to_end {
    use std::signer;

    use betting_app::betting_app;

    #[test(aptos_framework = @aptos_framework, deployer = @message_board_addr, sender = @0x100)]
    fun test_end_to_end(aptos_framework: &signer, deployer: &signer, sender: &signer) {
        let _sender_addr = signer::address_of(sender);
        betting_app::init_module_for_test(aptos_framework, deployer);
    }
}

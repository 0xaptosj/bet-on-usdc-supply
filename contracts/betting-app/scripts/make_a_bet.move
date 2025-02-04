script {
    use betting_app_addr::betting_app;

    // This Move script runs atomically, i.e. it creates 2 messages in the same transaction.
    // Move script is how we batch multiple function calls in 1 tx
    // Similar to Solana allows multiple instructions in 1 tx
    fun make_a_bet(sender: &signer) {
        // bet i oAPT on yes
        betting_app::place_bet(sender, true, 1);
    }
}

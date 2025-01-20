use starknet::ContractAddress;
use openzeppelin::token::erc20::{ERC20ABIDispatcher, ERC20ABIDispatcherTrait};
use core::byte_array::{ByteArray};

const ORACLE_ADDRESS: felt252 = 0x44ac84b04789b0a2afcdd2eb914f0f9b767a77a95a019ebaadc28d6cacbaeeb;
const ASSERT_TRUTH_IDENTIFIER: felt252 = 'ASSERT_TRUTH'; // Standard identifier for truth assertions

#[derive(starknet::Store, Drop, Serde, Copy)]
struct Bet {
    initiator: ContractAddress,
    opponent: ContractAddress,
    amount: u256,
    currency: ERC20ABIDispatcher,
    assertion_id: felt252,
    settled: bool,
    initiator_claimed_victory: bool,
    expiration_time: u64,
    liveness_period: u64,
    bond_amount: u256,
}

#[derive(starknet::Store, Drop, Serde, Copy)]
pub struct EscalationManagerSettings {
    pub arbitrate_via_escalation_manager: bool,
    pub discard_oracle: bool,
    pub validate_disputers: bool,
    pub asserting_caller: ContractAddress,
    pub escalation_manager: ContractAddress,
}

#[derive(starknet::Store, Drop, Serde, Copy)]
pub struct Assertion {
    pub escalation_manager_settings: EscalationManagerSettings,
    pub asserter: ContractAddress,
    pub assertion_time: u64,
    pub settled: bool,
    pub currency: ERC20ABIDispatcher,
    pub expiration_time: u64,
    pub settlement_resolution: bool,
    pub domain_id: u256,
    pub identifier: felt252,
    pub bond: u256,
    pub callback_recipient: ContractAddress,
    pub disputer: ContractAddress,
}

#[starknet::interface]
pub trait IOptimisticOracle<TContractState> {
    fn assert_truth_with_defaults(
        ref self: TContractState, claim: ByteArray, asserter: ContractAddress,
    ) -> felt252;

    fn assert_truth(
        ref self: TContractState,
        claim: ByteArray,
        asserter: ContractAddress,
        callback_recipient: ContractAddress,
        escalation_manager: ContractAddress,
        liveness: u64,
        currency: ERC20ABIDispatcher,
        bond: u256,
        identifier: felt252,
        domain_id: u256,
    ) -> felt252;

    fn dispute_assertion(
        ref self: TContractState, assertion_id: felt252, disputer: ContractAddress,
    );

    fn settle_assertion(ref self: TContractState, assertion_id: felt252);

    fn get_minimum_bond(self: @TContractState, currency: ContractAddress) -> u256;

    fn stamp_assertion(self: @TContractState, assertion_id: felt252) -> ByteArray;

    fn default_identifier(self: @TContractState) -> felt252;

    fn get_assertion(self: @TContractState, assertion_id: felt252) -> Assertion;

    fn sync_params(ref self: TContractState, identifier: felt252, currency: ContractAddress);

    fn settle_and_get_assertion_result(ref self: TContractState, assertion_id: felt252) -> bool;

    fn get_assertion_result(self: @TContractState, assertion_id: felt252) -> bool;

    fn set_admin_properties(
        ref self: TContractState,
        default_currency: ContractAddress,
        default_liveness: u64,
        burned_bond_percentage: u256,
    );
}

#[starknet::interface]
trait IBettingContract<TContractState> {
    fn create_bet(
        ref self: TContractState,
        opponent: ContractAddress,
        amount: u256,
        currency: ContractAddress,
        expiration_time: u64,
        liveness_period: u64,
    ) -> felt252;

    fn accept_bet(ref self: TContractState, bet_id: felt252);
    fn claim_victory(ref self: TContractState, bet_id: felt252, claim_description: ByteArray);
    fn dispute_victory(ref self: TContractState, bet_id: felt252);
    fn settle_bet(ref self: TContractState, bet_id: felt252);
    fn get_bet(self: @TContractState, bet_id: felt252) -> Bet;
    fn get_minimum_bond(self: @TContractState, currency: ContractAddress) -> u256;
}

#[starknet::contract]
mod BettingContract {
    use super::ERC20ABIDispatcherTrait;
    use super::{
        Bet, IBettingContract, ContractAddress, ERC20ABIDispatcher, ORACLE_ADDRESS,
        ASSERT_TRUTH_IDENTIFIER,
    };
    use starknet::{get_caller_address, get_block_timestamp, get_contract_address};
    use core::byte_array::{ByteArray};
    use crate::bet::{IOptimisticOracleDispatcher, IOptimisticOracleDispatcherTrait};
    use starknet::storage::{
        Map, StoragePathEntry, StoragePointerReadAccess, StoragePointerWriteAccess,
    };
    
    #[storage]
    struct Storage {
        bets: Map<felt252, Bet>,
        oracle: IOptimisticOracleDispatcher,
        next_bet_id: felt252,
    }

    #[constructor]
    fn constructor(ref self: ContractState) {
        self
            .oracle
            .write(
                IOptimisticOracleDispatcher {
                    contract_address: ORACLE_ADDRESS.try_into().unwrap(),
                },
            );
        self.next_bet_id.write(1);
    }

    #[abi(embed_v0)]
    impl BettingContractImpl of IBettingContract<ContractState> {
        fn create_bet(
            ref self: ContractState,
            opponent: ContractAddress,
            amount: u256,
            currency: ContractAddress,
            expiration_time: u64,
            liveness_period: u64,
        ) -> felt252 {
            // Validate inputs
            let caller = get_caller_address();
            assert(opponent != caller, 'Cannot bet against yourself');
            assert(expiration_time > get_block_timestamp(), 'Invalid expiration time');
            assert(liveness_period >= 3600, 'Liveness period too short'); // Minimum 1 hour

            // Get minimum bond required for the currency
            let oracle = self.oracle.read();
            let bond_amount = oracle.get_minimum_bond(currency);

            let bet_id = self.next_bet_id.read();
            self.next_bet_id.write(bet_id + 1);

            let bet = Bet {
                initiator: caller,
                opponent,
                amount,
                currency: ERC20ABIDispatcher { contract_address: currency },
                assertion_id: 0,
                settled: false,
                initiator_claimed_victory: false,
                expiration_time,
                liveness_period,
                bond_amount,
            };

            let currency_token = ERC20ABIDispatcher { contract_address: currency };
            // Transfer betting amount to contract
            currency_token.transfer_from(caller, get_contract_address(), amount);

            self.bets.entry(bet_id).write(bet);
            bet_id
        }

        fn accept_bet(ref self: ContractState, bet_id: felt252) {
            let mut bet = self.bets.entry(bet_id).read();
            let caller = get_caller_address();

            assert(caller == bet.opponent, 'Only opponent can accept');
            assert(!bet.settled, 'Bet already settled');
            assert(bet.assertion_id == 0, 'Bet already accepted');
            assert(get_block_timestamp() < bet.expiration_time, 'Bet expired');

            // Transfer betting amount from opponent
            bet.currency.transfer_from(caller, starknet::get_contract_address(), bet.amount);

            self.bets.entry(bet_id).write(bet);
        }

        fn claim_victory(ref self: ContractState, bet_id: felt252, claim_description: ByteArray) {
            let mut bet = self.bets.entry(bet_id).read();
            let caller = get_caller_address();

            assert(!bet.settled, 'Bet already settled');
            assert!(
                caller == bet.initiator || caller == bet.opponent,
                "Only initiator or opponent can claim",
            );
            assert(bet.assertion_id == 0, 'Victory already claimed');

            let oracle = self.oracle.read();

            // First approve oracle to spend bond amount
            bet.currency.approve(ORACLE_ADDRESS.try_into().unwrap(), bet.bond_amount);

            // Assert truth through oracle with all parameters specified
            let assertion_id = oracle
                .assert_truth(
                    claim_description, // Detailed claim about the victory
                    caller, // Asserter address
                    starknet::get_contract_address(), // Callback recipient (this contract)
                    0.try_into().unwrap(), // No escalation manager
                    bet.liveness_period, // Challenge period
                    bet.currency, // Currency for bond
                    bet.bond_amount, // Bond amount
                    ASSERT_TRUTH_IDENTIFIER, // Standard identifier for truth assertions
                    0 // No domain ID
                );

            bet.assertion_id = assertion_id;
            bet.initiator_claimed_victory = true;
            self.bets.entry(bet_id).write(bet);
        }

        fn dispute_victory(ref self: ContractState, bet_id: felt252) {
            let bet = self.bets.entry(bet_id).read();
            let caller = get_caller_address();

            assert(!bet.settled, 'Bet already settled');
            assert(caller == bet.opponent, 'Only opponent can dispute');
            assert(bet.assertion_id != 0, 'No victory claimed');

            // First approve oracle to spend bond amount
            bet.currency.approve(ORACLE_ADDRESS.try_into().unwrap(), bet.bond_amount);

            // Dispute through oracle
            let oracle = self.oracle.read();
            oracle.dispute_assertion(bet.assertion_id, caller);
        }

        fn settle_bet(ref self: ContractState, bet_id: felt252) {
            let mut bet = self.bets.entry(bet_id).read();
            assert(!bet.settled, 'Bet already settled');
            assert(bet.assertion_id != 0, 'No victory claimed');

            let oracle = self.oracle.read();
            let result = oracle.settle_and_get_assertion_result(bet.assertion_id);

            // Transfer funds based on oracle result
            let winner = if result {
                bet.initiator // Initiator's claim was true
            } else {
                bet.opponent // Initiator's claim was false
            };

            // Transfer total bet amount to winner
            let total_amount = bet.amount * 2;
            bet.currency.transfer(winner, total_amount);

            bet.settled = true;
            self.bets.entry(bet_id).write(bet);
        }

        fn get_bet(self: @ContractState, bet_id: felt252) -> Bet {
            self.bets.entry(bet_id).read()
        }

        fn get_minimum_bond(self: @ContractState, currency: ContractAddress) -> u256 {
            let oracle = self.oracle.read();
            oracle.get_minimum_bond(currency)
        }
    }
}

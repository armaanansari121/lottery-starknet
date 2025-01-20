use starknet::{ContractAddress, contract_address_const};

#[derive(Copy, Drop, Serde, starknet::Store, PartialEq)]
enum State {
    #[default]
    Active,
    WinnerSelected,
    Closed,
}

#[starknet::interface]
pub trait ILottery<TContractState> {
    fn enroll(ref self: TContractState);
    fn unenroll(ref self: TContractState);
    fn withdraw_oracle_fees(ref self: TContractState);
    fn get_lottery_details(
        self: @TContractState,
    ) -> (
        ContractAddress,
        Array<ContractAddress>,
        ContractAddress,
        u256,
        ContractAddress,
        State,
        u256,
    );
    fn get_participant_id(self: @TContractState, participant_address: ContractAddress) -> u64;
    fn is_enrolled(self: @TContractState, participant_address: ContractAddress) -> bool;
}

#[starknet::interface]
pub trait IPragmaVRF<TContractState> {
    fn get_last_random_number(self: @TContractState) -> felt252;
    fn select_winner(
        ref self: TContractState,
        seed: u64,
        callback_fee_limit: u128,
        publish_delay: u64,
        num_words: u64,
        calldata: Array<felt252>,
    );
    fn receive_random_words(
        ref self: TContractState,
        requester_address: ContractAddress,
        request_id: u64,
        random_words: Span<felt252>,
        calldata: Array<felt252>,
    );
}

pub fn Factory() -> ContractAddress {
    contract_address_const::<0x02f5814a6a3c29855972b58ae15f7ba2afa86ceb69a1f992a371e299402ca0d3>()
}

pub fn ETH() -> ContractAddress {
    contract_address_const::<0x049d36570d4e46f48e99674bd3fcc84644ddd6b96f7c741b1562b82f9e004dc7>()
}

pub fn ZeroAddress() -> ContractAddress {
    contract_address_const::<0x0000000000000000000000000000000000000000000000000000000000000000>()
}

#[starknet::contract]
mod Lottery {
    use starknet::{ContractAddress, get_caller_address, get_contract_address, get_block_number};
    use starknet::storage::{
        StoragePointerWriteAccess, StoragePointerReadAccess, Map, StoragePathEntry,
    };
    use pragma_lib::abi::{IRandomnessDispatcher, IRandomnessDispatcherTrait};
    use openzeppelin::access::ownable::OwnableComponent;
    use openzeppelin::token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
    use super::{State, Factory, ETH, ZeroAddress};
    use crate::factory::{ILotteryFactoryDispatcher, ILotteryFactoryDispatcherTrait};

    component!(path: OwnableComponent, storage: ownable, event: OwnableEvent);

    #[abi(embed_v0)]
    impl OwnableImpl = OwnableComponent::OwnableImpl<ContractState>;
    impl InternalImpl = OwnableComponent::InternalImpl<ContractState>;


    #[storage]
    struct Storage {
        owner: ContractAddress,
        token: ContractAddress,
        minimum_participants: u256,
        participant_fees: u256,
        winner: ContractAddress,
        state: State,
        next_participant_id: u64,
        participant_id_to_address: Map<u64, ContractAddress>,
        participant_address_to_id: Map<ContractAddress, u64>,
        // PragmaVRFOracle variables
        pragma_vrf_contract_address: ContractAddress,
        min_block_number_storage: u64,
        last_random_number: felt252,
        #[substorage(v0)]
        ownable: OwnableComponent::Storage,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        ParticipantEnrolled: ParticipantEnrolled,
        WinnerSelected: WinnerSelected,
        #[flat]
        OwnableEvent: OwnableComponent::Event,
    }

    #[derive(Drop, starknet::Event)]
    struct ParticipantEnrolled {
        participant: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    struct WinnerSelected {
        winner: ContractAddress,
        amount: u256,
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        owner: ContractAddress,
        minimum_participants: u256,
        participant_fees: u256,
        token_address: ContractAddress,
        pragma_vrf_contract_address: ContractAddress,
    ) {
        self.ownable.initializer(owner);
        self.owner.write(owner);
        self.minimum_participants.write(minimum_participants);
        self.participant_fees.write(participant_fees);
        self.token.write(token_address);
        self.next_participant_id.write(1);
        self.pragma_vrf_contract_address.write(pragma_vrf_contract_address);

        assert!(
            get_caller_address() == Factory(),
            "Lottery Contract can only be deployed by Factory Contract",
        );
    }

    #[abi(embed_v0)]
    impl ILottery of super::ILottery<ContractState> {
        fn enroll(ref self: ContractState) {
            assert!(self.state.read() == State::Active, "Lottery is not active");

            // Check if caller is enrolled
            let caller = get_caller_address();
            let factory_contract = ILotteryFactoryDispatcher { contract_address: Factory() };
            assert!(factory_contract.is_registered(caller), "Caller is not registered");
            assert!(!self.is_enrolled(caller), "Caller is already enrolled");

            // Check if caller has enough balance
            let token = IERC20Dispatcher { contract_address: self.token.read() };
            let balance = token.balance_of(caller);
            let participant_fees = self.participant_fees.read();
            assert!(balance >= participant_fees, "Caller does not have enough balance");

            // Check if contract has enough allowance to spend fees
            let this = get_contract_address();
            let allowance = token.allowance(caller, this);
            assert!(
                allowance >= participant_fees,
                "Contract does not have enough allowance to spend fees",
            );

            // Transfer fees to contract
            let success = token.transfer_from(caller, this, participant_fees);
            assert!(success, "Transfer failed");

            // Add caller to participants
            let next_participant_id = self.next_participant_id.read();
            self.participant_id_to_address.entry(next_participant_id).write(caller);
            self.participant_address_to_id.entry(caller).write(next_participant_id);
            self.next_participant_id.write(next_participant_id + 1);
            self.emit(ParticipantEnrolled { participant: caller });
        }

        fn unenroll(ref self: ContractState) {
            assert!(self.state.read() == State::Active, "Lottery is not active");

            // Check if caller is enrolled
            let caller = get_caller_address();
            assert!(self.is_enrolled(caller), "Caller is not enrolled");

            let token = IERC20Dispatcher { contract_address: self.token.read() };
            let participant_fees = self.participant_fees.read();

            let success = token.transfer(caller, participant_fees);
            assert!(success, "Transfer failed");

            let caller_id = self.participant_address_to_id.entry(caller).read();
            self.participant_address_to_id.entry(caller).write(0);
            self.participant_id_to_address.entry(caller_id).write(ZeroAddress());
        }

        fn withdraw_oracle_fees(ref self: ContractState) {
            self.ownable.assert_only_owner();
            assert!(self.state.read() == State::WinnerSelected, "Lottery is not over");
            let ETH = ETH();
            let token = IERC20Dispatcher { contract_address: ETH };
            let this = get_contract_address();
            let balance = token.balance_of(this);
            let success = token.transfer(self.owner.read(), balance);
            assert!(success, "Transfer failed");
            self.state.write(State::Closed);
        }

        fn get_lottery_details(
            self: @ContractState,
        ) -> (
            ContractAddress,
            Array<ContractAddress>,
            ContractAddress,
            u256,
            ContractAddress,
            State,
            u256,
        ) {
            let owner = self.owner.read();
            let participants = self._get_participants();
            let token = self.token.read();
            let participant_fees = self.participant_fees.read();
            let winner = self.winner.read();
            let state = self.state.read();
            let minimum_participants = self.minimum_participants.read();
            (owner, participants, token, participant_fees, winner, state, minimum_participants)
        }

        fn get_participant_id(self: @ContractState, participant_address: ContractAddress) -> u64 {
            self.participant_address_to_id.entry(participant_address).read()
        }

        fn is_enrolled(self: @ContractState, participant_address: ContractAddress) -> bool {
            let participant_id = self.participant_address_to_id.entry(participant_address).read();
            participant_id != 0
        }
    }

    #[generate_trait]
    impl InternalFunctions of InternalFunctionsTrait {
        fn _get_winner(ref self: ContractState) {
            // Check if lottery is active
            assert!(self.state.read() == State::Active, "Lottery is not active");

            let participants: Array<ContractAddress> = self._get_participants();
            let number_of_participants = participants.len().into();
            let participant_fees = self.participant_fees.read();

            // Get winner
            let random_number: u256 = self.last_random_number.read().into();
            let reduced_random_number: u32 = (random_number % number_of_participants)
                .try_into()
                .unwrap();
            let winner: ContractAddress = *participants.at(reduced_random_number);
            self.winner.write(winner);

            // Transfer winnings to winner
            let token = IERC20Dispatcher { contract_address: self.token.read() };
            let total_winnings = number_of_participants * participant_fees;
            let platform_fee = total_winnings / 100;
            let winner_share = total_winnings - platform_fee;
            let success = token.transfer(winner, winner_share);
            assert!(success, "Transfer failed");
            let success = token.transfer(Factory(), platform_fee);
            assert!(success, "Transfer failed");

            // Emit event
            self.emit(WinnerSelected { winner, amount: total_winnings });

            // Close lottery
            self.state.write(State::WinnerSelected);
        }

        fn _get_balance(self: @ContractState) -> u256 {
            // Get balance of contract
            let token = IERC20Dispatcher { contract_address: self.token.read() };
            let this = get_contract_address();
            let balance = token.balance_of(this);
            balance
        }

        fn _get_participants(self: @ContractState) -> Array<ContractAddress> {
            let mut participants = ArrayTrait::new();
            for id in 1..self.next_participant_id.read() {
                if self.participant_id_to_address.entry(id).read() != ZeroAddress() {
                    participants.append(self.participant_id_to_address.entry(id).read());
                }
            };
            participants
        }
    }

    #[abi(embed_v0)]
    impl PragmaVRFOracle of super::IPragmaVRF<ContractState> {
        fn get_last_random_number(self: @ContractState) -> felt252 {
            let last_random = self.last_random_number.read();
            last_random
        }

        fn select_winner(
            ref self: ContractState,
            seed: u64,
            callback_fee_limit: u128,
            publish_delay: u64,
            num_words: u64,
            calldata: Array<felt252>,
        ) {
            self.ownable.assert_only_owner();
            assert!(self.state.read() == State::Active, "Lottery is not active");

            let number_of_participants: u256 = self._get_participants().len().into();
            let minimum_participants = self.minimum_participants.read();
            assert!(number_of_participants >= minimum_participants, "Not enough participants");

            let randomness_contract_address = self.pragma_vrf_contract_address.read();
            let randomness_dispatcher = IRandomnessDispatcher {
                contract_address: randomness_contract_address,
            };

            // Approve the randomness contract to transfer the callback fee
            // You would need to send some ETH to this contract first to cover the fees
            let eth_dispatcher = IERC20Dispatcher {
                contract_address: ETH() // ETH Contract Address
            };

            eth_dispatcher
                .approve(
                    randomness_contract_address,
                    (callback_fee_limit + callback_fee_limit / 5).into(),
                );

            // Request the randomness
            randomness_dispatcher
                .request_random(
                    seed,
                    get_contract_address(),
                    callback_fee_limit,
                    publish_delay,
                    num_words,
                    calldata,
                );

            let current_block_number = get_block_number();
            self.min_block_number_storage.write(current_block_number + publish_delay);
        }

        fn receive_random_words(
            ref self: ContractState,
            requester_address: ContractAddress,
            request_id: u64,
            random_words: Span<felt252>,
            calldata: Array<felt252>,
        ) {
            // Have to make sure that the caller is the Pragma Randomness Oracle contract
            let caller_address = get_caller_address();
            assert(
                caller_address == self.pragma_vrf_contract_address.read(),
                'caller not randomness contract',
            );
            // and that the current block is within publish_delay of the request block
            let current_block_number = get_block_number();
            let min_block_number = self.min_block_number_storage.read();
            assert(min_block_number <= current_block_number, 'block number issue');

            let random_word = *random_words.at(0);
            self.last_random_number.write(random_word);

            self._get_winner();
        }
    }
}

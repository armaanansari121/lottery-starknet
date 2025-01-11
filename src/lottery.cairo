use starknet::{ContractAddress};

#[starknet::interface]
pub trait ILottery<TContractState> {
    fn enroll(ref self: TContractState);
    fn withdraw_oracle_fees(ref self: TContractState);
    fn get_balance(self: @TContractState) -> u256;
    fn get_participants(self: @TContractState) -> Array<ContractAddress>;
}

#[starknet::interface]
pub trait IPragmaVRF<TContractState> {
    fn get_last_random_number(self: @TContractState) -> felt252;
    fn request_randomness_from_pragma(
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

#[starknet::contract]
mod Lottery {
    use starknet::{
        ContractAddress, get_caller_address, get_contract_address, get_block_number,
        contract_address_const,
    };
    use starknet::storage::{
        StoragePointerWriteAccess, StoragePointerReadAccess, Vec, VecTrait, MutableVecTrait,
    };
    use pragma_lib::abi::{IRandomnessDispatcher, IRandomnessDispatcherTrait};
    use openzeppelin::access::ownable::OwnableComponent;
    use openzeppelin::token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};

    component!(path: OwnableComponent, storage: ownable, event: OwnableEvent);

    #[abi(embed_v0)]
    impl OwnableImpl = OwnableComponent::OwnableImpl<ContractState>;
    impl InternalImpl = OwnableComponent::InternalImpl<ContractState>;

    #[derive(Copy, Drop, Serde, starknet::Store, PartialEq)]
    enum State {
        #[default]
        Active,
        WinnerSelected,
        Closed,
    }

    #[storage]
    struct Storage {
        owner: ContractAddress,
        participants: Vec<ContractAddress>,
        token: ContractAddress,
        participant_fees: u256,
        winner: ContractAddress,
        state: State,
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
        participant_fees: u256,
        token_address: ContractAddress,
        pragma_vrf_contract_address: ContractAddress,
    ) {
        self.ownable.initializer(owner);
        self.owner.write(owner);
        self.participant_fees.write(participant_fees);
        self.token.write(token_address);
        self.pragma_vrf_contract_address.write(pragma_vrf_contract_address);
    }

    #[abi(embed_v0)]
    impl ILottery of super::ILottery<ContractState> {
        fn enroll(ref self: ContractState) {
            assert!(self.state.read() == State::Active, "Lottery is not active");

            // Check if caller is enrolled
            let caller = get_caller_address();
            assert!(!self._already_enrolled(caller), "Caller is already enrolled");

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
            self.participants.append().write(caller);
            self.emit(ParticipantEnrolled { participant: caller });
        }

        fn withdraw_oracle_fees(ref self: ContractState) {
            self.ownable.assert_only_owner();
            assert!(self.state.read() == State::WinnerSelected, "Lottery is not over");
            let ETH = contract_address_const::<0x049d36570d4e46f48e99674bd3fcc84644ddd6b96f7c741b1562b82f9e004dc7>();
            let token = IERC20Dispatcher { contract_address: ETH };
            let this = get_contract_address();
            let balance = token.balance_of(this);
            let success = token.transfer(self.owner.read(), balance);
            assert!(success, "Transfer failed");
            self.state.write(State::Closed);
        }

        fn get_balance(self: @ContractState) -> u256 {
            // Get balance of contract
            let token = IERC20Dispatcher { contract_address: self.token.read() };
            let this = get_contract_address();
            let balance = token.balance_of(this);
            balance
        }

        fn get_participants(self: @ContractState) -> Array<ContractAddress> {
            let mut participants = ArrayTrait::new();
            for i in 0..self.participants.len() {
                participants.append(self.participants.at(i).read());
            };
            participants
        }
    }

    #[generate_trait]
    impl InternalFunctions of InternalFunctionsTrait {
        fn _already_enrolled(self: @ContractState, user: ContractAddress) -> bool {
            let mut found = false;
            for i in 0..self.participants.len() {
                if self.participants.at(i).read() == user {
                    found = true;
                }
            };
            found
        }

        fn _get_winner(ref self: ContractState) {
            // Check if lottery is active
            assert!(self.state.read() == State::Active, "Lottery is not active");

            let number_of_participants = self.participants.len().into();
            let participant_fees = self.participant_fees.read();

            // Get winner
            let random_number: u256 = self.last_random_number.read().into();
            let reduced_random_number: u64 = (random_number % number_of_participants)
                .try_into()
                .unwrap();
            let winner = self.participants.at(reduced_random_number).read();
            self.winner.write(winner);

            // Transfer winnings to winner
            let token = IERC20Dispatcher { contract_address: self.token.read() };
            let winnings = number_of_participants * participant_fees;
            let success = token.transfer(winner, winnings);
            assert!(success, "Transfer failed");

            // Emit event
            self.emit(WinnerSelected { winner, amount: winnings });

            // Close lottery
            self.state.write(State::WinnerSelected);
        }
    }

    #[abi(embed_v0)]
    impl PragmaVRFOracle of super::IPragmaVRF<ContractState> {
        fn get_last_random_number(self: @ContractState) -> felt252 {
            let last_random = self.last_random_number.read();
            last_random
        }

        fn request_randomness_from_pragma(
            ref self: ContractState,
            seed: u64,
            callback_fee_limit: u128,
            publish_delay: u64,
            num_words: u64,
            calldata: Array<felt252>,
        ) {
            self.ownable.assert_only_owner();

            assert!(self.state.read() == State::Active, "Lottery is not active");

            let randomness_contract_address = self.pragma_vrf_contract_address.read();
            let randomness_dispatcher = IRandomnessDispatcher {
                contract_address: randomness_contract_address,
            };

            // Approve the randomness contract to transfer the callback fee
            // You would need to send some ETH to this contract first to cover the fees
            let eth_dispatcher = IERC20Dispatcher {
                contract_address: contract_address_const::<
                    0x049d36570d4e46f48e99674bd3fcc84644ddd6b96f7c741b1562b82f9e004dc7,
                >() // ETH Contract Address
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

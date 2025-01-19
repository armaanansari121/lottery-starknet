use starknet::{ContractAddress, ClassHash, contract_address_const};

#[derive(Drop, Serde, starknet::Store)]
struct LotteryDetails {
    lottery_address: ContractAddress,
    token: ContractAddress,
    participant_fees: u256,
}

#[derive(Drop, Serde, starknet::Store)]
struct Profile {
    is_registered: bool,
    username: ByteArray,
    profile_picture: ByteArray,
    bio: ByteArray,
}

pub fn ETH() -> ContractAddress {
    contract_address_const::<0x049d36570d4e46f48e99674bd3fcc84644ddd6b96f7c741b1562b82f9e004dc7>()
}

#[starknet::interface]
pub trait ILotteryFactory<TContractState> {
    fn register_user(
        ref self: TContractState, username: ByteArray, profile_picture: ByteArray, bio: ByteArray,
    );
    fn create_lottery(
        ref self: TContractState,
        token: ContractAddress,
        minimum_participants: u256,
        participant_fees: u256,
        salt: felt252,
    ) -> ContractAddress;
    fn update_pragma_vrf_contract_address(
        ref self: TContractState, new_pragma_vrf_contract_address: ContractAddress,
    );
    fn update_lottery_class_hash(ref self: TContractState, new_lottery_class_hash: ClassHash);
    fn withdraw(ref self: TContractState, token: ContractAddress, amount: u256);
    fn get_lotteries(self: @TContractState) -> Array<LotteryDetails>;
    fn is_registered(self: @TContractState, user_address: ContractAddress) -> bool;
    fn get_user_profile(self: @TContractState, user_address: ContractAddress) -> Profile;
}

#[starknet::contract]
pub mod Factory {
    use OwnableComponent::InternalTrait;
    use starknet::{
        ContractAddress, ClassHash, syscalls::deploy_syscall, get_caller_address,
        get_contract_address,
    };
    use starknet::storage::{
        StoragePointerWriteAccess, StoragePointerReadAccess, Vec, VecTrait, MutableVecTrait, Map,
        StoragePathEntry,
    };
    use super::LotteryDetails;
    use openzeppelin::access::ownable::OwnableComponent;
    use openzeppelin::token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
    use super::{Profile, ETH};

    component!(path: OwnableComponent, storage: ownable, event: OwnableEvent);

    #[abi(embed_v0)]
    impl OwnableImpl = OwnableComponent::OwnableImpl<ContractState>;
    impl InternalImpl = OwnableComponent::InternalImpl<ContractState>;

    #[storage]
    struct Storage {
        /// Store the constructor arguments of the contract to deploy
        pragma_vrf_contract_address: ContractAddress,
        /// Store the class hash of the contract to deploy
        lottery_class_hash: ClassHash,
        /// Deployed lottery contracts
        deployed_lotteries: Vec<LotteryDetails>,
        users: Map<ContractAddress, Profile>,
        #[substorage(v0)]
        ownable: OwnableComponent::Storage,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        LotteryCreated: LotteryCreated,
        #[flat]
        OwnableEvent: OwnableComponent::Event,
    }

    #[derive(Drop, starknet::Event)]
    struct LotteryCreated {
        lottery_address: ContractAddress,
        token: ContractAddress,
        participant_fees: u256,
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        pragma_vrf_contract_address: ContractAddress,
        lottery_class_hash: ClassHash,
        owner: ContractAddress,
    ) {
        self.pragma_vrf_contract_address.write(pragma_vrf_contract_address);
        self.lottery_class_hash.write(lottery_class_hash);
        self.ownable.initializer(owner);
    }

    #[abi(embed_v0)]
    impl Factory of super::ILotteryFactory<ContractState> {
        fn register_user(
            ref self: ContractState,
            username: ByteArray,
            profile_picture: ByteArray,
            bio: ByteArray,
        ) {
            let user_address = get_caller_address();
            assert!(!self.is_registered(user_address), "User is already registered");
            let profile = Profile { is_registered: true, username, profile_picture, bio };
            self.users.entry(user_address).write(profile);
        }

        fn create_lottery(
            ref self: ContractState,
            token: ContractAddress,
            minimum_participants: u256,
            participant_fees: u256,
            salt: felt252,
        ) -> ContractAddress {
            assert!(self.is_registered(get_caller_address()), "User is not registered");
            // Constructor arguments
            let mut constructor_calldata: Array::<felt252> = array![];
            Serde::serialize(@get_caller_address(), ref constructor_calldata);
            Serde::serialize(@minimum_participants, ref constructor_calldata);
            Serde::serialize(@participant_fees, ref constructor_calldata);
            Serde::serialize(@token, ref constructor_calldata);
            Serde::serialize(@self.pragma_vrf_contract_address.read(), ref constructor_calldata);

            // Contract deployment
            let (deployed_address, _) = deploy_syscall(
                self.lottery_class_hash.read(), salt, constructor_calldata.span(), false,
            )
                .unwrap();

            // Transfer oracle fees to the deployed contract
            let token_dispatcher = IERC20Dispatcher { contract_address: ETH() };
            let pragma_vrf_oracle_fees = 20_000_000_000_000_000;
            assert!(
                token_dispatcher
                    .allowance(
                        get_caller_address(), get_contract_address(),
                    ) >= pragma_vrf_oracle_fees,
                "Contract does not have enough allowance to fund the oracle",
            );
            assert!(
                token_dispatcher.balance_of(get_caller_address()) >= pragma_vrf_oracle_fees,
                "Caller does not have enough balance to fund the oracle",
            );
            let success = token_dispatcher
                .transfer_from(get_caller_address(), deployed_address, pragma_vrf_oracle_fees);
            assert!(success, "Failed to transfer oracle fees");

            // Store the address
            self
                .deployed_lotteries
                .append()
                .write(
                    LotteryDetails { lottery_address: deployed_address, token, participant_fees },
                );

            // Emit event
            self
                .emit(
                    LotteryCreated { lottery_address: deployed_address, token, participant_fees },
                );

            deployed_address
        }

        fn get_lotteries(self: @ContractState) -> Array<LotteryDetails> {
            let mut lotteries = ArrayTrait::new();
            for i in 0..self.deployed_lotteries.len() {
                lotteries.append(self.deployed_lotteries.at(i).read());
            };
            lotteries
        }

        fn withdraw(ref self: ContractState, token: ContractAddress, amount: u256) {
            self.ownable.assert_only_owner();
            let token_dispatcher = IERC20Dispatcher { contract_address: token };
            let balance = token_dispatcher.balance_of(get_contract_address());
            assert!(balance >= amount, "Not enough balance to withdraw");
            let success = token_dispatcher.transfer(get_caller_address(), amount);
            assert!(success, "Failed to withdraw");
        }

        fn update_pragma_vrf_contract_address(
            ref self: ContractState, new_pragma_vrf_contract_address: ContractAddress,
        ) {
            self.ownable.assert_only_owner();
            self.pragma_vrf_contract_address.write(new_pragma_vrf_contract_address);
        }

        fn update_lottery_class_hash(ref self: ContractState, new_lottery_class_hash: ClassHash) {
            self.ownable.assert_only_owner();
            self.lottery_class_hash.write(new_lottery_class_hash);
        }

        fn is_registered(self: @ContractState, user_address: ContractAddress) -> bool {
            let profile = self.users.entry(user_address).read();
            profile.is_registered
        }

        fn get_user_profile(self: @ContractState, user_address: ContractAddress) -> Profile {
            self.users.entry(user_address).read()
        }
    }
}

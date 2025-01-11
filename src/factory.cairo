pub use starknet::{ContractAddress, ClassHash};

#[starknet::interface]
pub trait ILotteryFactory<TContractState> {
    /// Create a new lottery contract
    fn create_lottery(
        ref self: TContractState, token: ContractAddress, participant_fees: u256,
    ) -> ContractAddress;

    /// Get the lotteries contract addresses
    fn get_lotteries(self: @TContractState) -> Array<ContractAddress>;

    /// Update the pragma vrf contract address
    fn update_pragma_vrf_contract_address(
        ref self: TContractState, new_pragma_vrf_contract_address: ContractAddress,
    );

    /// Update the class hash of the lottery contract to deploy when creating a new lottery
    fn update_lottery_class_hash(ref self: TContractState, new_lottery_class_hash: ClassHash);
}

#[starknet::contract]
pub mod Factory {
    use OwnableComponent::InternalTrait;
    use starknet::{ContractAddress, ClassHash, syscalls::deploy_syscall, get_caller_address, get_contract_address, contract_address_const};
    use starknet::storage::{
        StoragePointerWriteAccess, StoragePointerReadAccess, Vec, VecTrait, MutableVecTrait,
    };
    use openzeppelin::access::ownable::OwnableComponent;
    use openzeppelin::token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};

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
        deployed_lotteries: Vec<ContractAddress>,
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
        fn create_lottery(
            ref self: ContractState, token: ContractAddress, participant_fees: u256,
        ) -> ContractAddress {
            // Constructor arguments
            let mut constructor_calldata: Array::<felt252> = array![];
            Serde::serialize(@get_caller_address(), ref constructor_calldata);
            Serde::serialize(@participant_fees, ref constructor_calldata);
            Serde::serialize(@token, ref constructor_calldata);
            Serde::serialize(@self.pragma_vrf_contract_address.read(), ref constructor_calldata);

            // Contract deployment
            let (deployed_address, _) = deploy_syscall(
                self.lottery_class_hash.read(), 0, constructor_calldata.span(), false,
            )
                .unwrap();

            // Transfer oracle fees to the deployed contract
            let ETH = contract_address_const::<0x49d36570d4e46f48e99674bd3fcc84644ddd6b96f7c741b1562b82f9e004dc7>();
            let token_dispatcher = IERC20Dispatcher { contract_address: ETH };
            let pragma_vrf_oracle_fees = 20_000_000_000_000_000;
            assert!(
                token_dispatcher
                    .allowance(get_caller_address(), get_contract_address()) >= pragma_vrf_oracle_fees,
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
            self.deployed_lotteries.append().write(deployed_address);

            // Emit event
            self
                .emit(
                    LotteryCreated { lottery_address: deployed_address, token, participant_fees },
                );

            deployed_address
        }

        fn get_lotteries(self: @ContractState) -> Array<ContractAddress> {
            let mut lotteries = ArrayTrait::new();
            for i in 0..self.deployed_lotteries.len() {
                lotteries.append(self.deployed_lotteries.at(i).read());
            };
            lotteries
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
    }
}

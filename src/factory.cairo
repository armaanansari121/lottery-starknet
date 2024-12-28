pub use starknet::{ContractAddress, ClassHash};
 
#[starknet::interface]
pub trait ILotteryFactory<TContractState> {
    /// Create a new lottery contract
    fn create_lottery(ref self: TContractState, token: ContractAddress, participant_fees: u256) -> ContractAddress;
 
    /// Get the lotteries contract addresses
    fn get_lotteries(self: @TContractState) -> Array<ContractAddress>;

    /// Update the pragma vrf contract address
    fn update_pragma_vrf_contract_address(ref self: TContractState, new_pragma_vrf_contract_address: ContractAddress);
 
    /// Update the class hash of the lottery contract to deploy when creating a new lottery
    fn update_lottery_class_hash(ref self: TContractState, new_lottery_class_hash: ClassHash);
}
 
#[starknet::contract]
pub mod factory {
    use OwnableComponent::InternalTrait;
use starknet::{ContractAddress, ClassHash, syscalls::deploy_syscall, get_caller_address};
    use starknet::storage::{
        StoragePointerWriteAccess, StoragePointerReadAccess, Vec, VecTrait, MutableVecTrait,
    };
    use openzeppelin::access::ownable::OwnableComponent;

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
       participant_fees: u256
    }
 
    #[constructor]
    fn constructor(ref self: ContractState, pragma_vrf_contract_address: ContractAddress, lottery_class_hash: ClassHash) {
        self.pragma_vrf_contract_address.write(pragma_vrf_contract_address);
        self.lottery_class_hash.write(lottery_class_hash);
        self.ownable.initializer(get_caller_address());
    }
 
    #[abi(embed_v0)]
    impl Factory of super::ILotteryFactory<ContractState> {
        fn create_lottery(ref self: ContractState, token: ContractAddress, participant_fees: u256) -> ContractAddress {
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

            // Store the address
            self.deployed_lotteries.append().write(deployed_address);
            
            // Emit event
            self.emit(LotteryCreated{ lottery_address: deployed_address, token, participant_fees });

            deployed_address
        }

        fn get_lotteries(self: @ContractState) -> Array<ContractAddress> {
            let mut lotteries = ArrayTrait::new();
            for i in 0..self.deployed_lotteries.len() {
                lotteries.append(self.deployed_lotteries.at(i).read());
            };
            lotteries
        }
 
        fn update_pragma_vrf_contract_address(ref self: ContractState, new_pragma_vrf_contract_address: ContractAddress) {
            self.ownable.assert_only_owner();
            self.pragma_vrf_contract_address.write(new_pragma_vrf_contract_address);
        }
 
        fn update_lottery_class_hash(ref self: ContractState, new_lottery_class_hash: ClassHash) {
            self.ownable.assert_only_owner();
            self.lottery_class_hash.write(new_lottery_class_hash);
        }
    }
}
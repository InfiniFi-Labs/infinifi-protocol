mkdir -p abi

forge inspect ./src/funding/MintController.sol:MintController abi --json > ./abi/MintController.json
echo "MintController abi generated"

forge inspect ./src/funding/RedeemController.sol:RedeemController abi --json > ./abi/RedeemController.json
echo "RedeemController abi generated"

forge inspect ./src/finance/YieldSharing.sol:YieldSharing abi --json > ./abi/YieldSharing.json
echo "YieldSharing abi generated"

forge inspect ./src/finance/Accounting.sol:Accounting abi --json > ./abi/Accounting.json
echo "Accounting abi generated"

forge inspect ./src/gateway/InfiniFiGatewayV1.sol:InfiniFiGatewayV1 abi --json > ./abi/InfiniFiGatewayV1.json
echo "InfiniFiGatewayV1 abi generated"

forge inspect ./src/governance/AllocationVoting.sol:AllocationVoting abi --json > ./abi/AllocationVoting.json
echo "AllocationVoting abi generated"

forge inspect ./src/integrations/Farm.sol:Farm abi --json > ./abi/Farm.json
echo "Farm abi generated"

forge inspect ./src/integrations/FarmRegistry.sol:FarmRegistry abi --json > ./abi/FarmRegistry.json
echo "FarmRegistry abi generated"

forge inspect ./src/integrations/farms/movement/ManualRebalancer.sol:ManualRebalancer abi --json > ./abi/ManualRebalancer.json
echo "ManualRebalancer abi generated"

forge inspect ./src/locking/LockingController.sol:LockingController abi --json > ./abi/LockingController.json
echo "LockingController abi generated"

forge inspect ./src/locking/UnwindingModule.sol:UnwindingModule abi --json > ./abi/UnwindingModule.json
echo "UnwindingModule abi generated"
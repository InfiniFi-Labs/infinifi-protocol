-include .env

.PHONY: test-unit test-integration coverage format slither abi

DEFAULT_ANVIL_KEY := 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80

test-unit :; forge test --match-path './test/unit/**' -vvv

test-integration :; forge test --match-contract IntegrationTest --fork-url $(MAINNET_RPC) -vvv

test-deployment :; forge test --match-contract ProtocolUpgradeCheck --fork-url $(MAINNET_RPC) -vvv

coverage :; forge coverage --match-path './test/unit/**' --report summary --report lcov

format :; forge fmt

deploy-poc :; ETH_PRIVATE_KEY=${TESTNET_DEPLOYER_KEY} forge script script/DeployPoC.s.sol --rpc-url $(TESTNET_RPC_URL) --broadcast

abi :; ./generate-abi.sh

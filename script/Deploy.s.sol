// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {VmSafe} from "forge-std/Vm.sol";
import {Script} from "forge-std/Script.sol";
import {console2 as console} from "forge-std/console2.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {CoreRoles} from "@libraries/CoreRoles.sol";

import {Config} from "./Config.s.sol";
import {ContractRegistry} from "./ContractRegistry.s.sol";
import {VerboseDeployment} from "./VerboseDeployment.s.sol";
import "./ContractRegistry.s.sol";

contract Deploy is Config, VerboseDeployment, ContractRegistry {
    modifier deployment(string memory prefix, string memory description) {
        console.log(string.concat(prefix, ": ", description));
        _;
        console.log(string.concat(prefix, ": Completed\n"));
    }

    function run() public {
        console.log("Deployer: Initiating full infiniFi protocol deployment");
        uint256 gas = gasleft();
        uint256 ts = block.timestamp;
        vm.warp(vm.unixTime());

        vm.startBroadcast();
        {
            // Order is important. Do not change
            deployCoreContract().deployFarmAdministration().deployTokens().deployLockingSystem().deployFinance()
                .deployAllocationVoting().deployStakingSystem();
        }
        vm.stopBroadcast();

        outputAddressesToJson(env);
        console.log("Deployment completed with %ss duration and %s gas consumed", block.timestamp - ts, gas - gasleft());
    }

    function deployCoreContract() public deployment("Core", "Deploying core InfiniFi contract") returns (Deploy) {
        core = new InfiniFiCore();
        json = vm.serializeAddress("root", "core", address(core));
        assignGoverningRoles();
        return this;
    }

    function deployFarmAdministration()
        public
        deployment("FarmAdministration", "Deploying farmRegistry & farmRebalancer")
        returns (Deploy)
    {
        require(address(core) != address(0), "FarmAdministration: _core is zero address");
        farmRegistry = new FarmRegistry(address(core));
        farmRebalancer = new FarmRebalancer(address(core), address(farmRegistry));
        core.grantRole(CoreRoles.FARM_MANAGER, address(farmRebalancer));
        string memory _json = "{}";
        _json = vm.serializeAddress("farmAdministration", "farmRegistry", address(farmRegistry));
        _json = vm.serializeAddress("farmAdministration", "farmRebalancer", address(farmRebalancer));
        json = vm.serializeString("root", "farmAdministration", _json);
        return this;
    }

    function deployTokens() public deployment("Tokens", "Deploying receipt & staking token") returns (Deploy) {
        // Deploy tokens
        receiptToken = new ReceiptToken(address(core), "infiniFi USD", "iUSD");
        stakedToken = new StakedToken(address(core), address(receiptToken));
        core.grantRole(CoreRoles.RECEIPT_TOKEN_BURNER, address(stakedToken));
        string memory _json = "{}";
        _json = vm.serializeAddress("tokens", "receiptToken", address(receiptToken));
        _json = vm.serializeAddress("tokens", "stakedToken", address(stakedToken));
        json = vm.serializeString("root", "tokens", _json);
        return (this);
    }

    function deployLockingSystem()
        public
        deployment("Locking", "Deploying locking system with unwinding module")
        returns (Deploy)
    {
        require(address(core) != address(0), "Locking: _core is zero address");
        require(address(receiptToken) != address(0), "Locking: _receiptToken is zero address");
        unwindingModule = new UnwindingModule(address(core), address(receiptToken));
        lockingController = new LockingController(address(core), address(receiptToken), address(unwindingModule));
        console.log("Locking: Deployed core locking contracts. Deploying Position tokens...");
        string memory _json = "{}";
        _json = vm.serializeAddress("locking", "lockingController", address(lockingController));
        _json = vm.serializeAddress("locking", "unwindingModule", address(unwindingModule));
        for (uint32 i = 1; i <= 13; i++) {
            LockedPositionToken _token = new LockedPositionToken(
                address(core),
                string.concat("Locked iUSD - ", Strings.toString(i), " weeks"),
                string.concat("liUSD-", Strings.toString(i), "w")
            );
            lockedPositionTokens.push(_token);
            console.log("Locking: Deployed %sw position token", i);
            // TODO: Determine initial multipliers
            lockingController.enableBucket(i, address(_token), 1e18 + 0.02e18 * uint256(i));
            _json = vm.serializeAddress("locking", string.concat("liUSD-", Strings.toString(i), "w"), address(_token));
        }

        json = vm.serializeString("root", "locking", _json);

        core.grantRole(CoreRoles.RECEIPT_TOKEN_BURNER, address(unwindingModule));
        core.grantRole(CoreRoles.RECEIPT_TOKEN_BURNER, address(lockingController));
        core.grantRole(CoreRoles.LOCKED_TOKEN_MANAGER, address(lockingController));

        return this;
    }

    function deployFinance() public deployment("Accounting", "Deploying accounting & oracles") returns (Deploy) {
        require(address(core) != address(0), "Accounting: _core is zero address");
        require(address(farmRegistry) != address(0), "Accounting: _farmRegistry is zero address");
        require(address(receiptToken) != address(0), "Accounting: _receiptToken is zero address");
        require(address(stakedToken) != address(0), "Accounting: _stakedToken is zero address");
        require(address(lockingController) != address(0), "Accounting: _lockingController is zero address");
        accounting = new Accounting(address(core), address(farmRegistry));
        yieldSharing = new YieldSharing(
            address(core), address(accounting), address(receiptToken), address(stakedToken), address(lockingController)
        );
        receiptTokenOracle = new FixedPriceOracle(address(core), RECEIPT_TOKEN_ORACLE_PRECISION);
        collateralOracle = new FixedPriceOracle(address(core), COLLATERAL_ORACLE_NORMALIZATION);
        console.log("Accounting: Setting oracles on accounting contract...");
        accounting.setOracle(address(receiptToken), address(receiptTokenOracle));
        accounting.setOracle(address(USDC_MAINNET_ADDRESS), address(collateralOracle));

        core.grantRole(CoreRoles.ORACLE_MANAGER, address(accounting));
        core.grantRole(CoreRoles.ORACLE_MANAGER, address(yieldSharing));
        core.grantRole(CoreRoles.FINANCE_MANAGER, address(yieldSharing));
        core.grantRole(CoreRoles.RECEIPT_TOKEN_MINTER, address(yieldSharing));
        core.grantRole(CoreRoles.RECEIPT_TOKEN_BURNER, address(yieldSharing));

        string memory _json = "{}";
        _json = vm.serializeAddress("finance", "accounting", address(accounting));
        _json = vm.serializeAddress("finance", "yieldSharing", address(yieldSharing));
        _json = vm.serializeAddress("finance", "oracleReceiptToken", address(receiptTokenOracle));
        _json = vm.serializeAddress("finance", "oracleCollateral", address(collateralOracle));
        json = vm.serializeString("root", "finance", _json);
        return this;
    }

    function deployAllocationVoting()
        public
        deployment("AllocationVoting", "Deploying allocation voting contract")
        returns (Deploy)
    {
        require(address(farmRegistry) != address(0), "AllocationVoting: _farmRegistry is zero address");
        require(address(lockingController) != address(0), "AllocationVoting: _lockingController is zero address");
        allocationVoting = new AllocationVoting(address(core), address(lockingController), address(farmRegistry));
        core.grantRole(CoreRoles.ACTION_RESTRICTOR, address(allocationVoting));
        json = vm.serializeAddress("root", "allocationVoting", address(allocationVoting));
        return this;
    }

    function deployStakingSystem()
        public
        deployment("Staking", "Deploying staking controller contract & hooks")
        returns (Deploy)
    {
        require(address(core) != address(0), "Staking: _core is zero address");
        require(address(accounting) != address(0), "Staking: _accounting is zero address");
        require(address(stakedToken) != address(0), "Staking: _stakedToken is zero address");
        require(address(receiptToken) != address(0), "Staking: _receiptToken is zero address");

        mintController =
            new MintController(address(core), address(USDC_MAINNET_ADDRESS), address(receiptToken), address(accounting));
        redeemController = new RedeemController(
            address(core), address(USDC_MAINNET_ADDRESS), address(receiptToken), address(accounting)
        );

        afterMintHook = new AfterMintHook(address(core), address(accounting), address(allocationVoting));
        beforeRedeemHook = new BeforeRedeemHook(address(core), address(accounting), address(allocationVoting));
        console.log("Hooks: Hooks deployed. Updating controller references...");
        MintController(address(mintController)).setAfterMintHook(address(afterMintHook));
        RedeemController(address(redeemController)).setBeforeRedeemHook(address(beforeRedeemHook));

        core.grantRole(CoreRoles.FARM_MANAGER, address(afterMintHook));
        core.grantRole(CoreRoles.FARM_MANAGER, address(beforeRedeemHook));
        core.grantRole(CoreRoles.ACTION_RESTRICTOR, address(mintController));
        core.grantRole(CoreRoles.RECEIPT_TOKEN_MINTER, address(mintController));
        core.grantRole(CoreRoles.RECEIPT_TOKEN_BURNER, address(redeemController));

        string memory _json = "{}";
        _json = vm.serializeAddress("staking", "mintController", address(mintController));
        _json = vm.serializeAddress("staking", "redeemController", address(redeemController));
        _json = vm.serializeAddress("staking", "afterMintHook", address(afterMintHook));
        _json = vm.serializeAddress("staking", "beforeRedeemHook", address(beforeRedeemHook));
        json = vm.serializeString("root", "staking", _json);
        return this;
    }

    function assignGoverningRoles()
        public
        deployment("Roles", "Assigning governing roles to external contracts and EOAs")
    {
        core.grantRole(CoreRoles.GOVERNOR, governorAddress);
        core.grantRole(CoreRoles.GUARDIAN, guardianAddress);
        // TODO: Determine what this role should be
        core.grantRole(CoreRoles.EXECUTOR_ROLE, address(0));
        core.grantRole(CoreRoles.PROPOSER_ROLE, timelockAddress);
        core.grantRole(CoreRoles.CANCELLER_ROLE, timelockAddress);

        core.grantRole(CoreRoles.FARM_MANAGER, farmManagerAddress);
        core.grantRole(CoreRoles.ORACLE_MANAGER, oracleManagerAddress);
        core.grantRole(CoreRoles.FARM_SWAP_CALLER, multisigAddress);
        core.grantRole(CoreRoles.FARM_MANAGER_ADMIN, multisigAddress);
    }
}

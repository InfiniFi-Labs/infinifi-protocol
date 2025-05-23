pragma solidity 0.8.28;

import {Vm} from "@forge-std/Vm.sol";
import {console} from "@forge-std/console.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {Timelock} from "@governance/Timelock.sol";
import {FarmTypes} from "@libraries/FarmTypes.sol";
import {CoreRoles} from "@libraries/CoreRoles.sol";
import {Accounting} from "@finance/Accounting.sol";
import {StakedToken} from "@tokens/StakedToken.sol";
import {InfiniFiTest} from "@test/InfiniFiTest.t.sol";
import {InfiniFiCore} from "@core/InfiniFiCore.sol";
import {FarmRegistry} from "@integrations/FarmRegistry.sol";
import {ReceiptToken} from "@tokens/ReceiptToken.sol";
import {YieldSharing} from "@finance/YieldSharing.sol";
import {MintController} from "@funding/MintController.sol";
import {UnwindingModule} from "@locking/UnwindingModule.sol";
import {AddressStoreLib} from "@deployment/AddressStoreLib.sol";
import {RedeemController} from "@funding/RedeemController.sol";
import {AllocationVoting} from "@governance/AllocationVoting.sol";
import {FixedPriceOracle} from "@finance/oracles/FixedPriceOracle.sol";
import {ManualRebalancer} from "@integrations/farms/movement/ManualRebalancer.sol";
import {LockingController} from "@locking/LockingController.sol";
import {InfiniFiGatewayV1} from "@gateway/InfiniFiGatewayV1.sol";
import {MinorRolesManager} from "@governance/MinorRolesManager.sol";
import {LockedPositionToken} from "@tokens/LockedPositionToken.sol";
import {EmergencyWithdrawal} from "@integrations/farms/movement/EmergencyWithdrawal.sol";
import {ProtocolUpgradeCheck} from "@test/integration/deployment/ProtocolUpgradeCheck.sol";

contract ProtocolUpgradeFixture is ProtocolUpgradeCheck {
    using AddressStoreLib for Vm;

    address public msig;
    ERC20 public usdc;
    Timelock public longTimelock;
    Timelock public shortTimelock;
    Accounting public accounting;
    StakedToken public siusd;
    YieldSharing public yieldSharing;
    InfiniFiCore public core;
    FarmRegistry public farmRegistry;
    ReceiptToken public iusd;
    MintController public mintController;
    UnwindingModule public unwindingModule;
    ManualRebalancer public manualRebalancer;
    FixedPriceOracle public oracleIusd;
    FixedPriceOracle public oracleUsdc;
    RedeemController public redeemController;
    AllocationVoting public allocationVoting;
    LockingController public lockingController;
    InfiniFiGatewayV1 public gateway;
    MinorRolesManager public minorRolesManager;
    EmergencyWithdrawal public emergencyWithdrawal;

    function setUp() public override {
        super.setUp();

        msig = vm.getAddr("TEAM_MULTISIG");
        usdc = ERC20(vm.getAddr("ERC20_USDC"));
        longTimelock = Timelock(payable(vm.getAddr("TIMELOCK_LONG")));
        shortTimelock = Timelock(payable(vm.getAddr("TIMELOCK_SHORT")));
        accounting = Accounting(vm.getAddr("ACCOUNTING"));
        siusd = StakedToken(vm.getAddr("STAKED_TOKEN"));
        yieldSharing = YieldSharing(vm.getAddr("YIELD_SHARING"));
        core = InfiniFiCore(vm.getAddr("CORE"));
        farmRegistry = FarmRegistry(vm.getAddr("FARM_REGISTRY"));
        iusd = ReceiptToken(vm.getAddr("RECEIPT_TOKEN"));
        mintController = MintController(vm.getAddr("MINT_CONTROLLER"));
        unwindingModule = UnwindingModule(vm.getAddr("UNWINDING_MODULE"));
        manualRebalancer = ManualRebalancer(vm.getAddr("MANUAL_REBALANCER"));
        oracleIusd = FixedPriceOracle(vm.getAddr("ORACLE_IUSD"));
        oracleUsdc = FixedPriceOracle(vm.getAddr("ORACLE_USDC"));
        redeemController = RedeemController(vm.getAddr("REDEEM_CONTROLLER"));
        allocationVoting = AllocationVoting(vm.getAddr("ALLOCATION_VOTING"));
        lockingController = LockingController(vm.getAddr("LOCKING_CONTROLLER"));
        gateway = InfiniFiGatewayV1(vm.getAddr("GATEWAY_PROXY"));
        minorRolesManager = MinorRolesManager(vm.getAddr("MINOR_ROLES_MANAGER"));
        emergencyWithdrawal = EmergencyWithdrawal(vm.getAddr("EMERGENCY_WITHDRAWAL"));
    }
}

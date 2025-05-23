pragma solidity 0.8.28;

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {Fixture} from "@test/Fixture.t.sol";
import {console} from "@forge-std/console.sol";
import {MockFarm} from "@test/mock/MockFarm.sol";
import {Timelock} from "@governance/Timelock.sol";
import {FarmTypes} from "@libraries/FarmTypes.sol";
import {CoreRoles} from "@libraries/CoreRoles.sol";
import {MockERC20} from "@test/mock/MockERC20.sol";
import {Accounting} from "@finance/Accounting.sol";
import {StakedToken} from "@tokens/StakedToken.sol";
import {InfiniFiTest} from "@test/InfiniFiTest.t.sol";
import {InfiniFiCore} from "@core/InfiniFiCore.sol";
import {FarmRegistry} from "@integrations/FarmRegistry.sol";
import {ReceiptToken} from "@tokens/ReceiptToken.sol";
import {YieldSharing} from "@finance/YieldSharing.sol";
import {MintController} from "@funding/MintController.sol";
import {UnwindingModule} from "@locking/UnwindingModule.sol";
import {RedeemController} from "@funding/RedeemController.sol";
import {AllocationVoting} from "@governance/AllocationVoting.sol";
import {FixedPriceOracle} from "@finance/oracles/FixedPriceOracle.sol";
import {ManualRebalancer} from "@integrations/farms/movement/ManualRebalancer.sol";
import {LockingController} from "@locking/LockingController.sol";
import {InfiniFiGatewayV1} from "@gateway/InfiniFiGatewayV1.sol";
import {MinorRolesManager} from "@governance/MinorRolesManager.sol";
import {LockedPositionToken} from "@tokens/LockedPositionToken.sol";
import {EmergencyWithdrawal} from "@integrations/farms/movement/EmergencyWithdrawal.sol";

// Main Fixture and configuration for preparing test environment
abstract contract Fixture is InfiniFiTest {
    address public alice = makeAddr("Alice");
    address public bob = makeAddr("Bob");
    address public carol = makeAddr("Carol");
    address public danny = makeAddr("Danny");
    address public msig = makeAddr("Multisig");
    address public keeper = makeAddr("Keeper");
    address public governorAddress = makeAddr("GOVERNOR_ADDRESS");
    address public parametersAddress = makeAddr("PARAMETERS_ADDRESS");
    address public guardianAddress = makeAddr("GUARDIAN_ADDRESS");
    address public farmManagerAddress = makeAddr("FARM_MANAGER_ADDRESS");
    address public timelockAddress = makeAddr("TIMELOCK_ADDRESS");
    address public oracleManagerAddress = makeAddr("ORACLE_MANAGER_ADDRESS");

    InfiniFiCore public core;
    FarmRegistry public farmRegistry;
    ReceiptToken public iusd;
    StakedToken public siusd;
    MockERC20 public usdc;
    MockFarm public farm1;
    MockFarm public farm2;
    MockFarm public illiquidFarm1;
    MockFarm public illiquidFarm2;
    ManualRebalancer public manualRebalancer;
    Accounting public accounting;
    YieldSharing public yieldSharing;
    FixedPriceOracle public oracleIusd;
    FixedPriceOracle public oracleUsdc;
    MintController public mintController;
    RedeemController public redeemController;
    UnwindingModule public unwindingModule;
    LockingController public lockingController;
    AllocationVoting public allocationVoting;
    Timelock public longTimelock;
    InfiniFiGatewayV1 public gateway;
    MinorRolesManager public minorRolesManager;
    EmergencyWithdrawal public emergencyWithdrawal;

    // this function is required to ignore this file from coverage
    function test() public pure virtual override {}

    function setUp() public virtual {
        // setup some non-zero block & timestamp
        vm.warp(1733412513);
        vm.roll(21337193);

        // deploy everything
        core = new InfiniFiCore();
        farmRegistry = new FarmRegistry(address(core));
        iusd = new ReceiptToken(address(core), "InfiniFi USD", "iUSD");
        siusd = new StakedToken(address(core), address(iusd));
        usdc = new MockERC20("Circle USD", "USDC");
        usdc.setDecimals(6);
        farm1 = new MockFarm(address(core), address(usdc));
        farm2 = new MockFarm(address(core), address(usdc));
        illiquidFarm1 = new MockFarm(address(core), address(usdc));
        illiquidFarm2 = new MockFarm(address(core), address(usdc));
        manualRebalancer = new ManualRebalancer(address(core), address(farmRegistry));
        accounting = new Accounting(address(core), address(farmRegistry));
        oracleIusd = new FixedPriceOracle(address(core), 1e18); // 1$ with 18 decimals of precision
        oracleUsdc = new FixedPriceOracle(address(core), 1e30); // 1$ + 12 decimals of normalization
        mintController = new MintController(address(core), address(usdc), address(iusd), address(accounting));
        redeemController = new RedeemController(address(core), address(usdc), address(iusd), address(accounting));
        unwindingModule = new UnwindingModule(address(core), address(iusd));
        lockingController = new LockingController(address(core), address(iusd), address(unwindingModule));
        yieldSharing = new YieldSharing(
            address(core), address(accounting), address(iusd), address(siusd), address(lockingController)
        );
        allocationVoting = new AllocationVoting(address(core), address(lockingController), address(farmRegistry));
        longTimelock = new Timelock(address(core), 30 days);
        address gatewayImplementation = address(new InfiniFiGatewayV1());
        gateway = InfiniFiGatewayV1(
            address(
                new TransparentUpgradeableProxy(
                    gatewayImplementation,
                    address(longTimelock),
                    abi.encodeWithSelector(InfiniFiGatewayV1.init.selector, address(core))
                )
            )
        );
        minorRolesManager = new MinorRolesManager(address(core));
        emergencyWithdrawal = new EmergencyWithdrawal(address(core), address(mintController));

        // labels
        vm.label(address(core), "core");
        vm.label(address(farmRegistry), "farmRegistry");
        vm.label(address(iusd), "iusd");
        vm.label(address(siusd), "siusd");
        vm.label(address(usdc), "usdc");
        vm.label(address(farm1), "farm1");
        vm.label(address(farm2), "farm2");
        vm.label(address(manualRebalancer), "manualRebalancer");
        vm.label(address(accounting), "accounting");
        vm.label(address(yieldSharing), "yieldSharing");
        vm.label(address(oracleIusd), "oracleIusd");
        vm.label(address(oracleUsdc), "oracleUsdc");
        vm.label(address(mintController), "mintController");
        vm.label(address(redeemController), "redeemController");
        vm.label(address(allocationVoting), "allocationVoting");
        vm.label(address(lockingController), "lockingController");
        vm.label(address(unwindingModule), "unwindingModule");
        vm.label(address(longTimelock), "longTimelock");
        vm.label(address(gateway), "gateway");
        vm.label(address(minorRolesManager), "minorRolesManager");
        vm.label(address(emergencyWithdrawal), "emergencyWithdrawal");

        // configure access control
        core.grantRole(CoreRoles.GOVERNOR, governorAddress);
        core.grantRole(CoreRoles.GOVERNOR, address(minorRolesManager));
        core.grantRole(CoreRoles.PAUSE, guardianAddress);
        core.grantRole(CoreRoles.PAUSE, address(emergencyWithdrawal));
        core.grantRole(CoreRoles.UNPAUSE, guardianAddress);
        core.grantRole(CoreRoles.UNPAUSE, address(emergencyWithdrawal));
        core.grantRole(CoreRoles.MINOR_ROLES_MANAGER, msig);
        core.grantRole(CoreRoles.PROTOCOL_PARAMETERS, parametersAddress);
        core.grantRole(CoreRoles.ENTRY_POINT, address(gateway));
        core.grantRole(CoreRoles.RECEIPT_TOKEN_MINTER, address(yieldSharing));
        core.grantRole(CoreRoles.RECEIPT_TOKEN_MINTER, address(mintController));
        core.grantRole(CoreRoles.RECEIPT_TOKEN_BURNER, address(redeemController));
        core.grantRole(CoreRoles.LOCKED_TOKEN_MANAGER, address(lockingController));
        core.grantRole(CoreRoles.RECEIPT_TOKEN_BURNER, address(siusd));
        core.grantRole(CoreRoles.TRANSFER_RESTRICTOR, address(allocationVoting));
        core.grantRole(CoreRoles.FARM_MANAGER, address(manualRebalancer));
        core.grantRole(CoreRoles.FARM_MANAGER, farmManagerAddress);
        core.grantRole(CoreRoles.FARM_MANAGER, address(emergencyWithdrawal));
        core.grantRole(CoreRoles.MANUAL_REBALANCER, msig);
        core.grantRole(CoreRoles.PERIODIC_REBALANCER, keeper);
        core.grantRole(CoreRoles.EMERGENCY_WITHDRAWAL, msig);
        core.grantRole(CoreRoles.FARM_SWAP_CALLER, msig);
        core.grantRole(CoreRoles.ORACLE_MANAGER, oracleManagerAddress);
        core.grantRole(CoreRoles.ORACLE_MANAGER, address(yieldSharing));
        core.grantRole(CoreRoles.ORACLE_MANAGER, address(accounting));
        core.grantRole(CoreRoles.FINANCE_MANAGER, address(yieldSharing));
        core.grantRole(CoreRoles.PROPOSER_ROLE, timelockAddress);
        core.grantRole(CoreRoles.EXECUTOR_ROLE, address(0));
        core.grantRole(CoreRoles.CANCELLER_ROLE, timelockAddress);
        core.grantRole(CoreRoles.RECEIPT_TOKEN_BURNER, address(lockingController));
        core.grantRole(CoreRoles.RECEIPT_TOKEN_BURNER, address(unwindingModule));
        core.grantRole(CoreRoles.RECEIPT_TOKEN_BURNER, address(yieldSharing));

        // configure contracts
        // gateway
        gateway.setAddress("USDC", address(usdc));
        gateway.setAddress("mintController", address(mintController));
        gateway.setAddress("redeemController", address(redeemController));
        gateway.setAddress("stakedToken", address(siusd));
        gateway.setAddress("receiptToken", address(iusd));
        gateway.setAddress("allocationVoting", address(allocationVoting));
        gateway.setAddress("lockingController", address(lockingController));
        gateway.setAddress("yieldSharing", address(yieldSharing));

        farmRegistry.enableAsset(address(usdc));

        siusd.setYieldSharing(address(yieldSharing));

        address[] memory protocolFarms = new address[](2);
        protocolFarms[0] = address(mintController);
        protocolFarms[1] = address(redeemController);
        vm.prank(parametersAddress);
        farmRegistry.addFarms(FarmTypes.PROTOCOL, protocolFarms);

        // farm registry
        address[] memory liquidFarms = new address[](2);
        liquidFarms[0] = address(farm1);
        liquidFarms[1] = address(farm2);
        vm.prank(parametersAddress);
        farmRegistry.addFarms(FarmTypes.LIQUID, liquidFarms);
        address[] memory illiquidFarms = new address[](2);
        illiquidFarms[0] = address(illiquidFarm1);
        illiquidFarms[1] = address(illiquidFarm2);
        vm.prank(parametersAddress);
        farmRegistry.addFarms(FarmTypes.MATURITY, illiquidFarms);

        // oracles config
        vm.startPrank(oracleManagerAddress);
        accounting.setOracle(address(iusd), address(oracleIusd));
        accounting.setOracle(address(usdc), address(oracleUsdc));
        vm.stopPrank();

        // locking module config
        for (uint32 i = 1; i <= 12; i++) {
            LockedPositionToken _token = new LockedPositionToken(
                address(core),
                string.concat("Locked iUSD - ", Strings.toString(i), " weeks"),
                string.concat("liUSD-", Strings.toString(i), "w")
            );
            vm.label(address(_token), _token.symbol());

            vm.prank(governorAddress);
            lockingController.enableBucket(i, address(_token), 1e18 + 0.02e18 * uint256(i));
        }

        // deployer renounces GOVERNOR role
        core.renounceRole(CoreRoles.GOVERNOR, address(this));
    }

    function _mintBackedReceiptTokens(address _to, uint256 _amount) internal {
        if (_amount == 0) return;

        uint256 usdcAmount = redeemController.receiptToAsset(_amount) + 1;
        usdc.mint(address(mintController), usdcAmount);

        vm.prank(address(mintController));
        iusd.mint(_to, _amount);
    }
}

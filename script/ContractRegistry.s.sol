// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// Finance
import {Accounting} from "@finance/Accounting.sol";
import {YieldSharing} from "@finance/YieldSharing.sol";

/// Governance
import {AllocationVoting} from "@governance/AllocationVoting.sol";

/// Integrations
import {FarmRegistry} from "@integrations/FarmRegistry.sol";
import {FarmRebalancer} from "@integrations/farms/movement/FarmRebalancer.sol";
import {UnwindingModule} from "@locking/UnwindingModule.sol";
import {FixedPriceOracle} from "@finance/oracles/FixedPriceOracle.sol";

/// Core
import {InfiniFiCore} from "@core/InfiniFiCore.sol";
import {LockingController} from "@locking/LockingController.sol";
import {MintController} from "@funding/MintController.sol";
import {RedeemController} from "@funding/RedeemController.sol";
import {AfterMintHook} from "@integrations/farms/movement/AfterMintHook.sol";
import {BeforeRedeemHook} from "@integrations/farms/movement/BeforeRedeemHook.sol";

/// Locking
import {LockingController} from "@locking/LockingController.sol";
import {UnwindingModule} from "@locking/UnwindingModule.sol";

/// Tokens
import {StakedToken} from "@tokens/StakedToken.sol";
import {ReceiptToken} from "@tokens/ReceiptToken.sol";
import {LockedPositionToken} from "@tokens/LockedPositionToken.sol";

abstract contract ContractRegistry {
    InfiniFiCore public core;
    Accounting public accounting;
    StakedToken public stakedToken;
    YieldSharing public yieldSharing;
    ReceiptToken public receiptToken;
    FarmRegistry public farmRegistry;
    FarmRebalancer public farmRebalancer;
    UnwindingModule public unwindingModule;
    AllocationVoting public allocationVoting;
    FixedPriceOracle public collateralOracle;
    FixedPriceOracle public receiptTokenOracle;
    LockingController public lockingController;
    MintController public mintController;
    RedeemController public redeemController;
    LockedPositionToken[] public lockedPositionTokens;

    AfterMintHook public afterMintHook;
    BeforeRedeemHook public beforeRedeemHook;

    // SwapFarm public swapFarm;
    // AaveV3Farm public aaveV3Farm;
    // ERC4626Farm public erc4626Farm;
}

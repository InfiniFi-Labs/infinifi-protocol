// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ERC4626Farm} from "@integrations/farms/ERC4626Farm.sol";

interface ISparkSUSDCVault {
    function deposit(uint256 assets, address receiver, uint256 minShares, uint16 refCode) external returns (uint256);
}

/// @title Spark sUSDC Farm
contract SparkSUSDCFarm is ERC4626Farm {
    using SafeERC20 for IERC20;

    address private constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address private constant SUSDC_VAULT = 0xBc65ad17c5C0a2A4D159fa5a503f4992c7B545FE;
    uint16 private constant SPARK_REF_CODE = 195;

    constructor(address _core) ERC4626Farm(_core, USDC, SUSDC_VAULT) {}

    function _deposit(uint256 availableAssets) internal override {
        IERC20(USDC).forceApprove(SUSDC_VAULT, availableAssets);

        // perform a deposit with infiniFi's ref code
        // and 0 minShares (regular deposit hardcodes to 0 so this is safe)
        ISparkSUSDCVault(SUSDC_VAULT).deposit(availableAssets, address(this), 0, SPARK_REF_CODE);
    }
}

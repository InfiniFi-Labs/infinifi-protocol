// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {MockPartialFarm} from "@test/mock/MockPartialFarm.sol";
import {FixedPointMathLib} from "@solmate/src/utils/FixedPointMathLib.sol";

contract BaseHookTest is Test {
    using FixedPointMathLib for uint256;

    MockPartialFarm public farm1;
    MockPartialFarm public farm2;
    MockPartialFarm public farm3;
    MockPartialFarm public controllerFarm = new MockPartialFarm(100 ether);

    uint256 constant PRECISION = 1e6;

    uint256 public amount;
    address[] public farms;
    uint256[] public weights;

    /// ============================================================
    /// Supporting contract mocks
    /// ============================================================

    function getAssetVoteWeights(address, uint256) public view returns (address[] memory, uint256[] memory, uint256) {
        return (farms, weights, _getTotalPower());
    }

    /// @notice Mocking the getVoteWeights function of the AllocationVoting contract
    function getVoteWeights(uint256) public view returns (address[] memory, uint256[] memory, uint256) {
        return (farms, weights, _getTotalPower());
    }

    /// @notice Mocking the totalLiquidAssets function of the Accounting contract
    function totalAssetsOf(address, uint256) public view returns (uint256) {
        return _getTotalAssets();
    }

    function hasRole(bytes32, address) public pure returns (bool) {
        return true;
    }

    /// ============================================================
    /// LiabilityHooks test configuration & helpers
    /// ============================================================

    // Assign assets to farms
    modifier configureFarms(uint256 _farm1Assets, uint256 _farm2Assets, uint256 _farm3Assets) {
        _configureFarms(_farm1Assets, _farm2Assets, _farm3Assets);
        _;
    }

    // Set weights for farms in percentage for making things easier
    modifier setWeights(uint256 weight1, uint256 weight2, uint256 weight3) {
        _setWeights(weight1, weight2, weight3);
        _;
    }

    modifier setAmount(uint256 _amount) {
        _setAmount(_amount);
        _;
    }

    function _configureFarms(uint256 _farm1Assets, uint256 _farm2Assets, uint256 _farm3Assets) private {
        farm1 = new MockPartialFarm(_farm1Assets);
        farm2 = new MockPartialFarm(_farm2Assets);
        farm3 = new MockPartialFarm(_farm3Assets);

        farms = [address(farm1), address(farm2), address(farm3)];
    }

    function _setWeights(uint256 weight1, uint256 weight2, uint256 weight3) private {
        weights = [weight1, weight2, weight3];
    }

    function _setAmount(uint256 _amount) private {
        amount = _amount;
    }

    function _getFarmAssetPercentage(address _farm) internal view returns (uint256) {
        return MockPartialFarm(_farm).assets().mulDivDown(PRECISION, _getTotalAssets());
    }

    function _getTotalPower() internal view returns (uint256) {
        return weights[0] + weights[1] + weights[2];
    }

    // Get total assets in all farms
    function _getTotalAssets() internal view returns (uint256) {
        return farm1.assets() + farm2.assets() + farm3.assets();
    }

    function testGetWeightsMock() public configureFarms(20 ether, 40 ether, 40 ether) setWeights(60, 20, 20) {
        (address[] memory _farms, uint256[] memory _weights, uint256 _totalPower) = getVoteWeights(0);
        assertEq(_farms.length, 3, "Should have 3 farms");
        assertEq(_weights.length, 3, "Should have 3 weights");
        assertEq(_totalPower, 100, "Total power should be 100");
    }

    function testTotalLiquidAssetsMock() public configureFarms(20 ether, 40 ether, 40 ether) {
        uint256 totalAssets = totalAssetsOf(address(0), 0);
        assertEq(totalAssets, 100 ether, "Total assets should be 100 ether");
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/console.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";

import {EthenaOracle} from "@finance/oracles/EthenaOracle.sol";
import {Mock4626} from "@test/mock/Mock4626.sol";
import {MockERC20} from "@test/mock/MockERC20.sol";
import {InfiniFiTest} from "@test/InfiniFiTest.t.sol";

contract EthenaOracleTest is InfiniFiTest {
    Mock4626 public mock4626;

    EthenaOracle public oracle;

    function setUp() public {
        oracle = new EthenaOracle();
        MockERC20 mockToken = new MockERC20("usde", "USDE");
        mock4626 = new Mock4626(address(mockToken));
        // etches a 4626 vault on sUSDe address
        bytes memory code = address(mock4626).code;
        vm.etch(address(oracle.sUSDe()), code);

        mock4626 = Mock4626(address(oracle.sUSDe()));
        mock4626.mockSharePrice(1e18);
    }

    function testPrice() public view {
        assertEq(oracle.price(), 1e18, "Error: Oracle price is not correct");
    }

    function testPriceNotOne() public {
        // if sUSDe convertToAssets ratio is 1.15
        // it means 1 sUSDe is 1.15 USDe
        mock4626.mockSharePrice(1.15e18);
        assertEq(oracle.price(), 1.15e18, "Error: Oracle price is not correct");
    }
}

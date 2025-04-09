pragma solidity 0.8.28;

import {IAfterMintHook} from "@interfaces/IMintController.sol";
import {IBeforeRedeemHook} from "@interfaces/IRedeemController.sol";

/// Not using MockFarm since it needs a token
contract MockPartialFarm {
    uint256 public assets;
    address public assetToken = address(0);

    function test() public pure virtual {}

    constructor(uint256 _assets) {
        assets = _assets;
    }

    function deposit() external {
        // noop
    }

    function directDeposit(uint256 _amount) external {
        assets += _amount;
    }

    function withdraw(uint256 _amount, address _farm) external {
        assets -= _amount;
        MockPartialFarm(_farm).directDeposit(_amount);
    }

    // Helper method to help with changing msg.sender
    // forge prank/hoax won't work with non-EOA in this case
    function callMintHook(IAfterMintHook _hooks, uint256 _amount) external {
        _hooks.afterMint(address(0), _amount, 0);
    }

    function callRedeemHook(IBeforeRedeemHook _hooks, uint256 _amount) external {
        _hooks.beforeRedeem(address(0), 0, _amount);
    }
}

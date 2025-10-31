// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {InfiniFiGatewayV2} from "@gateway/InfiniFiGatewayV2.sol";
import {MigrationController} from "@funding/MigrationController.sol";

/// @notice Gateway to interact with the InfiniFi protocol
contract InfiniFiGatewayV3 is InfiniFiGatewayV2 {
    using SafeERC20 for ERC20;

    function migrate(address _farm, address _token, uint256 _amount, uint32 _unwindingEpochs)
        external
        whenNotPaused
        nonReentrant
        returns (uint256)
    {
        ERC20 token = ERC20(_token);
        MigrationController migrationController = MigrationController(getAddress("migrationController"));

        token.safeTransferFrom(msg.sender, address(this), _amount);
        token.approve(address(migrationController), _amount);
        return migrationController.migrate(msg.sender, _farm, _token, _amount, _unwindingEpochs);
    }
}

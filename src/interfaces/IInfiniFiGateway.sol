// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AllocationVoting} from "@governance/AllocationVoting.sol";

/// @notice Interface for the InfiniFi gateway
interface IInfiniFiGateway {
    function setAddress(string memory _name, address _address) external;

    function getAddress(string memory _name) external view returns (address);

    function setEnabledRouter(address _router, bool _enabled) external;

    function setZapFee(uint256 _zapFee) external;

    function addresses(bytes32 _key) external view returns (address);

    function enabledRouters(address _router) external view returns (bool);

    function zapFee() external view returns (uint256);

    function mint(address _to, uint256 _amount) external returns (uint256);

    function mintAndStake(address _to, uint256 _amount) external returns (uint256);

    function stake(address _to, uint256 _receiptTokens) external returns (uint256);

    function unstake(address _to, uint256 _stakedTokens) external returns (uint256);

    function zapIn(address _token, uint256 _amount, address _router, bytes calldata _routerData, address _to)
        external
        payable
        returns (uint256);

    function zapInAndStake(address _token, uint256 _amount, address _router, bytes calldata _routerData, address _to)
        external
        payable
        returns (uint256);

    function zapInAndLock(
        address _token,
        uint256 _amount,
        address _router,
        bytes calldata _routerData,
        uint32 _unwindingEpochs,
        address _to
    ) external payable returns (uint256);

    function mintAndLock(address _to, uint256 _amount, uint32 _unwindingEpochs) external returns (uint256);

    function unstakeAndLock(address _to, uint256 _amount, uint32 _unwindingEpochs) external returns (uint256);

    function createPosition(uint256 _amount, uint32 _unwindingEpochs, address _recipient) external;

    function startUnwinding(uint256 _shares, uint32 _unwindingEpochs) external;

    function increaseUnwindingEpochs(uint32 _oldUnwindingEpochs, uint32 _newUnwindingEpochs, uint256 _shares) external;

    function cancelUnwinding(uint256 _unwindingTimestamp, uint32 _newUnwindingEpochs) external;

    function withdraw(uint256 _unwindingTimestamp) external;

    function redeem(address _to, uint256 _amount, uint256 _minAssetsOut) external returns (uint256);

    function claimRedemption() external;

    function vote(
        address _asset,
        uint32 _unwindingEpochs,
        AllocationVoting.AllocationVote[] calldata _liquidVotes,
        AllocationVoting.AllocationVote[] calldata _illiquidVotes
    ) external;

    function multiVote(
        address[] calldata _assets,
        uint32[] calldata _unwindingEpochs,
        AllocationVoting.AllocationVote[][] calldata _liquidVotes,
        AllocationVoting.AllocationVote[][] calldata _illiquidVotes
    ) external;

    function migrate(address _farm, address _token, uint256 _amount, uint32 _unwindingEpochs) external returns (uint256);
}

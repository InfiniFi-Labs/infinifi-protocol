# InfiniFi Protocol

## Overview

InfiniFi is a DeFi protocol that enables users to mint and redeem receipt tokens (iUSD, iETH) against collateral assets (USDC, ETH). The protocol features a sophisticated yield generation system through multiple farm integrations, a locking mechanism for enhanced rewards, and a governance system for farm allocation voting.

## Protocol Architecture

### Core Components

1. **Core Module** (`src/core/`)
   - `InfiniFiCore.sol`: Central contract managing roles and permissions
   - `CoreControlled.sol`: Base contract inherited by a lot of contracts to use access control

2. **Gateway** (`src/gateway/`)
   - `InfiniFiGatewayV1.sol`: Main entry point for user interactions
   - Handles minting, redeeming, locking, and voting operations

3. **Funding Module** (`src/funding/`)
   - `MintController.sol`: Manages receipt token minting
   - `RedeemController.sol`: Handles receipt token redemption requests and processing
   - `RedemptionPool.sol`: Abstract contract implementing a redemption queue
   - See also `tokens/ReceiptToken.sol`, the receipt token of the protocol (e.g. iUSD)

4. **Locking Module** (`src/locking/`)
   - `LockingController.sol`: Manages token locking and rewards
   - `UnwindingModule.sol`: Handles position unwinding
   - See also `tokens/LockedPositionToken.sol`, an ERC20 token representing locked positions

5. **Governance** (`src/governance/`)
   - `AllocationVoting.sol`: Manages farm allocation voting
   - Users can vote on how their locked tokens are allocated across farms

6. **Finance Module** (`src/finance/`)
   - `YieldSharing.sol`: Manages yield distribution
   - `Accounting.sol`: Handles protocol accounting

7. **Integrations** (`src/integrations/`)
   - `FarmRegistry.sol`: Manages farms list
   - `farms/movement/`: Contains code to move assets between farms
     - `ManualRebalancer.sol`: Manual movement of assets between farms
     - `AfterMintHook.sol`: Handles post-mint movement of assets
     - `BeforeRedeemHook.sol`: Manages pre-redeem movement of assets

### Key Features

1. **Minting and Redemption**
   - Users can mint receipt tokens (e.g. iUSD) by depositing collateral assets (e.g. USDC)
   - Redemptions are processed through a queue, popped instantly if the protocol has enough liquid assets
   - Minimum amounts can be enforced

2. **Locking Mechanism**
   - Users can lock their receipt tokens for enhanced rewards
   - Multiple locking durations are supported
   - Unwinding process for locked positions (locks last forever, but user has to trigger an "unwinding period" and wait for it to complete before withdrawing)

3. **Farm Integration**
   - Support for both liquid and illiquid farms (e.g. Aave, Pendle)
   - Dynamic farm allocation based on user votes
   - Automatic rebalancing through hooks
   - Manual rebalancing to illiquid farms performed manually at first

4. **Governance**
   - Weighted voting system based on locked tokens
   - Separate voting for liquid and illiquid farms
   - Epoch-based voting periods

## Security Considerations

### Critical Components

1. **Access Control**
   - Role-based access control through CoreControlled
   - Guardian role for emergency actions
   - Governor role for protocol parameters

2. **Asset Management**
   - Farm validation and registration
   - Asset type validation
   - Maturity checks for illiquid farms

3. **Voting System**
   - Weight validation
   - Epoch-based vote application
   - Vote expiration handling

### Potential Risk Areas

1. **Price Manipulation**
   - Farm yield calculations
   - Asset price oracles
   - Redemption value calculations

2. **Liquidity Management**
   - Farm rebalancing
   - Redemption queue processing

3. **Governance Attacks**
   - Vote weight manipulation
   - Farm allocation gaming
   - Parameter manipulation

## Testing

The protocol includes comprehensive test coverage:
- Unit tests for individual components
- Integration tests for system interactions & live protocols
- Fuzzing tests for edge cases

## Development Setup

1. Install dependencies:
```bash
forge install
```

2. Build the project:
```bash
forge build
```

3. Run tests:
```bash
make test-unit
```

4. Generate coverage report:
```bash
make coverage
```

## Audit Scope

The audit should focus on:
1. Smart contract security
2. Internal accounting and profit distributions
3. Access control implementation
4. Asset movements within the system and going in/out
5. Integration of 3rd party protocols

## Additional Resources

- Protocol Documentation: https://infinifilabs.atlassian.net/wiki/spaces/InfiniFi/pages/207814657/Architecture
- Technical Specification: https://www.notion.so/Audit-1a544c414f36809dbd0bd71087ee567e?pvs=13
- Test Coverage Report: https://github.com/InfiniFi-Labs/infinifi-contracts/actions/runs/13631904087

// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "@forge-std/console.sol";
import {Fixture} from "@test/Fixture.t.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IMintController} from "@interfaces/IMintController.sol";
import {ActionRestriction} from "@core/ActionRestriction.sol";
import {IRedeemController} from "@interfaces/IRedeemController.sol";

contract MintRedeemControllerUnitTest is Fixture {
    bool public afterMintHookCalled = false;
    bool public beforeRedeemHookCalled = false;

    // mint & redeem hooks
    function afterMint(address, uint256, uint256) external {
        afterMintHookCalled = true;
    }

    function beforeRedeem(address, uint256, uint256) external {
        beforeRedeemHookCalled = true;
    }

    uint256 constant IUSD_ORACLE_PRICE = 0.8e18;

    function setUp() public override {
        super.setUp();

        // by default set the iusd oracle price to 0.8
        vm.prank(oracleManagerAddress);
        oracleIusd.setPrice(IUSD_ORACLE_PRICE);

        afterMintHookCalled = false;
        beforeRedeemHookCalled = false;
    }

    function scenarioAliceMintWith1000USDCAndHalfIsAllocatedToFarm() private {
        usdc.mint(address(alice), 1000e6);
        vm.startPrank(alice);
        usdc.approve(address(gateway), 1000e6);
        gateway.mint(alice, 1000e6);
        vm.stopPrank();

        vm.warp(block.timestamp + 12);

        // burn USDC from the contract, so that we can test the redeem with not enough liquidity
        // in reality it should be because some USDC would have been alocated to a yield bearing farm
        // here we just burn USDC from the contract
        usdc.mockBurn(address(mintController), 500e6);
        // now only 500 USDC are left in the contract while alice still has 1000 iUSD
        assertEq(usdc.balanceOf(address(mintController)), 500e6);
    }

    function scenarioAliceRedeemsAllHerIUSD() private {
        // alice will try to redeem all her iUSD
        vm.startPrank(alice);
        iusd.approve(address(gateway), iusd.balanceOf(alice));
        gateway.redeem(alice, iusd.balanceOf(alice));
        vm.stopPrank();
    }

    function testInitialState() public view {
        // check contructor setup & default values for state variables
        assertEq(mintController.receiptToken(), address(iusd), "Error: mintController.receiptToken() should be iUSD");
        assertEq(mintController.assetToken(), address(usdc), "Error: mintController.assetToken() should be USDC");
        assertEq(
            mintController.accounting(), address(accounting), "Error: mintController.accounting() should be accounting"
        );
        assertEq(mintController.restrictionDuration(), 1, "Error: mintController.restrictionDuration() should be 1");
        assertEq(mintController.minMintAmount(), 1, "Error: mintController.minMintAmount() should be 1");
        assertEq(
            redeemController.receiptToken(), address(iusd), "Error: redeemController.receiptToken() should be iUSD"
        );
        assertEq(redeemController.assetToken(), address(usdc), "Error: redeemController.assetToken() should be USDC");
        assertEq(
            redeemController.accounting(),
            address(accounting),
            "Error: redeemController.accounting() should be accounting"
        );
        assertEq(redeemController.minRedemptionAmount(), 1, "Error: redeemController.minRedemptionAmount() should be 1");

        // asset & liquidity should be 0 at first
        assertEq(mintController.assets(), 0, "Error: mintController.assets() should be 0 at first");
        assertEq(mintController.liquidity(), 0, "Error: mintController.liquidity() should be 0 at first");
        assertEq(redeemController.assets(), 0, "Error: redeemController.assets() should be 0 at first");
        assertEq(redeemController.liquidity(), 0, "Error: redeemController.liquidity() should be 0 at first");
    }

    function testSetMinRedemptionAmountShouldErrorIfNotGovernor() public {
        vm.expectRevert("UNAUTHORIZED");
        redeemController.setMinRedemptionAmount(100);
    }

    function testSetMinRedemptionCannotBeZero() public {
        assertEq(redeemController.minRedemptionAmount(), 1);
        vm.prank(governorAddress);
        vm.expectRevert(abi.encodeWithSelector(IRedeemController.RedeemAmountTooLow.selector, 0, 1));
        redeemController.setMinRedemptionAmount(0);
    }

    function testSetMinRedemptionCanBeSetByGovernor(uint256 _amount) public {
        _amount = bound(_amount, 1, 1_000e18);
        assertEq(redeemController.minRedemptionAmount(), 1, "Error: redeemController.minRedemptionAmount() should be 1");
        vm.prank(governorAddress);
        redeemController.setMinRedemptionAmount(_amount);
        assertEq(
            redeemController.minRedemptionAmount(),
            _amount,
            "Error: redeemController.minRedemptionAmount() should be set to _amount"
        );
    }

    function testSetAfterMintHookShouldErrorIfNotGovernor() public {
        vm.expectRevert("UNAUTHORIZED");
        mintController.setAfterMintHook(address(this));
    }

    function testSetBeforeRedeemHookShouldErrorIfNotGovernor() public {
        vm.expectRevert("UNAUTHORIZED");
        redeemController.setBeforeRedeemHook(address(this));
    }

    function testSetAfterMintHookCanBeSetByGovernor(address _afterMintHook) public {
        vm.prank(governorAddress);
        mintController.setAfterMintHook(_afterMintHook);
        assertEq(mintController.afterMintHook(), _afterMintHook);
    }

    function testSetBeforeRedeemHookCanBeSetByGovernor(address _beforeRedeemHook) public {
        vm.prank(governorAddress);
        redeemController.setBeforeRedeemHook(_beforeRedeemHook);
        assertEq(redeemController.beforeRedeemHook(), _beforeRedeemHook);
    }

    function testSetMinMintAmountShouldErrorIfNotGovernor() public {
        vm.expectRevert("UNAUTHORIZED");
        mintController.setMinMintAmount(100);
    }

    function testSetMinMintCanBeSetByGovernor(uint256 _amount) public {
        _amount = bound(_amount, 1, 1_000e18);
        assertEq(mintController.minMintAmount(), 1, "Error: mintController.minMintAmount() should be 1 at default");
        vm.prank(governorAddress);
        mintController.setMinMintAmount(_amount);
        assertEq(
            mintController.minMintAmount(),
            _amount,
            "Error: mintController.minMintAmount() should be set to _amount after calling setMinMintAmount()"
        );
    }

    function testSetMinMintCannotBeZero() public {
        assertEq(mintController.minMintAmount(), 1, "Error: mintController.minMintAmount() should be 1 at default");
        vm.prank(governorAddress);
        vm.expectRevert(abi.encodeWithSelector(IMintController.MintAmountTooLow.selector, 0, 1));
        mintController.setMinMintAmount(0);
    }

    function testSetRestrictionDurationShouldErrorIfNotGovernor() public {
        vm.expectRevert("UNAUTHORIZED");
        mintController.setRestrictionDuration(100);
    }

    function testSetRestrictionDurationCanBeSetByGovernor(uint256 _duration) public {
        _duration = bound(_duration, 1, 100);
        assertEq(
            mintController.restrictionDuration(),
            1,
            "Error: mintController.restrictionDuration() should be 1 at default"
        );
        vm.prank(governorAddress);
        mintController.setRestrictionDuration(_duration);
        assertEq(
            mintController.restrictionDuration(),
            _duration,
            "Error: mintController.restrictionDuration() should be set to _duration after calling setRestrictionDuration()"
        );
    }

    function testAssetToReceipt(uint256 _amountAsset, uint256 _iusdPrice) public {
        _amountAsset = bound(_amountAsset, 0.1e6, 1_000_000_000e6);
        _iusdPrice = bound(_iusdPrice, 0.1e18, 1e18);
        uint256 assetPrice = 1e30;

        // set the new price of iusd
        vm.prank(oracleManagerAddress);
        oracleIusd.setPrice(_iusdPrice);

        // assetToReceipt should return the amount of receipt you get for a given amount of asset
        // if price is 1:1, 1 asset gives 1 receipt
        // if the iUSD price is < 1, then 1 asset gives more than 1 receipt
        uint256 amountReceipt = mintController.assetToReceipt(_amountAsset);
        uint256 expectedAmount = _amountAsset * 1e18 / (_iusdPrice * 1e18 / assetPrice);
        assertEq(
            amountReceipt,
            expectedAmount,
            "Error: mintController.assetToReceipt() does not return the correct amount of receipt"
        );

        if (_iusdPrice < 1e18) {
            // check that we received more iUSD than the amountAsset (with decimal correction)
            uint256 decimalCorrection = 1e12;
            assertGt(
                amountReceipt,
                _amountAsset * decimalCorrection,
                "Error: mintController.assetToReceipt() should be greater than the amountAsset if iUSD price is less than 1"
            );
        }
    }

    function testReceiptToAsset(uint256 _amountReceipt, uint256 _iusdPrice) public {
        _amountReceipt = bound(_amountReceipt, 0.1e18, 1_000_000_000e18);
        _iusdPrice = bound(_iusdPrice, 0.1e18, 1e18);
        uint256 assetPrice = 1e30;

        // set the new price of iusd
        vm.prank(oracleManagerAddress);
        oracleIusd.setPrice(_iusdPrice);

        uint256 amountAsset = redeemController.receiptToAsset(_amountReceipt);
        uint256 expectedAmount = _amountReceipt * (_iusdPrice * 1e18 / assetPrice) / 1e18;
        assertEq(
            amountAsset,
            expectedAmount,
            "Error: redeemController.receiptToAsset() does not return the correct amount of asset"
        );

        if (_iusdPrice < 1e18) {
            // check that we received less USDC than the amountReceipt (with decimal correction)
            uint256 decimalCorrection = 1e12;
            assertLt(
                amountAsset * decimalCorrection,
                _amountReceipt,
                "Error: redeemController.receiptToAsset() should be less than the amountReceipt if iUSD price is less than 1"
            );
        }
    }

    function testAssetsWithoutPendingClaims() public {
        // check that assets() returns the total assets of the redeemController
        assertEq(redeemController.assets(), 0, "Error: redeemController.assets() should be 0 at first");

        // we airdrop 1000 USDC to the redeemController
        usdc.mint(address(redeemController), 1000e6);
        assertEq(
            usdc.balanceOf(address(redeemController)),
            1000e6,
            "Error: redeemController.assets() should be 1000e6 after airdropping 1000 USDC"
        );

        // check that assets() returns the total assets of the redeemController
        assertEq(
            redeemController.assets(),
            1000e6,
            "Error: redeemController.assets() should be 1000e6 after airdropping 1000 USDC"
        );
    }

    // check that liquidity() returns the same as assets()
    function testLiquidityWithoutPendingClaims() public {
        testAssetsWithoutPendingClaims();
        assertEq(
            redeemController.liquidity(),
            redeemController.assets(),
            "Error: redeemController.liquidity() should be equal to redeemController.assets()"
        );
    }

    /// @notice alice deposits 1000 USDC, then we allocate 500 to another farm
    /// then alice redeems all her iUSD, which means that she get 500 USDC back and
    /// enqueue for a ticket with 500 iUSD
    function testAssetsWithPendingClaims() public {
        scenarioAliceMintWith1000USDCAndHalfIsAllocatedToFarm();

        // move funds from mintController to redeemController
        vm.startPrank(farmManagerAddress);
        mintController.withdraw(usdc.balanceOf(address(mintController)), address(redeemController));
        vm.stopPrank();

        scenarioAliceRedeemsAllHerIUSD();

        // if we now deposit 1000 USDC into the redeemController
        // 500 goes to the RQ, and 500 is left in the redeemController
        usdc.mint(address(redeemController), 1000e6);
        vm.prank(farmManagerAddress);
        redeemController.deposit();

        // the assets should be 500 because there are 500 total pending claims
        assertEq(
            redeemController.assets(),
            500e6,
            "Error: redeemController.assets() should be 500e6 because there are 500 total pending claims"
        );
    }

    function testLiquidityWithPendingClaims() public {
        testAssetsWithPendingClaims();
        assertEq(
            redeemController.liquidity(),
            redeemController.assets(),
            "Error: redeemController.liquidity() should be equal to redeemController.assets()"
        );
    }

    function testMintShouldRevertIfPaused() public {
        vm.prank(guardianAddress);
        mintController.pause();

        usdc.mint(address(this), 100e6);
        usdc.approve(address(gateway), 100e6);

        vm.expectRevert(abi.encodeWithSelector(Pausable.EnforcedPause.selector));
        gateway.mint(address(this), 100e6);
    }

    function testMintShouldRevertIfAssetAmountIsLessThanMinMintAmount(uint256 _mintAmount) public {
        _mintAmount = bound(_mintAmount, 1, 1_000_000e6);
        vm.prank(governorAddress);
        mintController.setMinMintAmount(_mintAmount + 1);

        usdc.mint(address(this), _mintAmount);
        usdc.approve(address(gateway), _mintAmount);

        vm.expectRevert(abi.encodeWithSelector(IMintController.MintAmountTooLow.selector, _mintAmount, _mintAmount + 1));
        gateway.mint(address(this), _mintAmount);
    }

    function testMint(uint256 _mintAmount, bool _setupAfterMintHook) public {
        _mintAmount = bound(_mintAmount, 1e6, 1_000_000_000e6);
        // give _mintAmount USDC to alice
        usdc.mint(address(alice), _mintAmount);

        if (_setupAfterMintHook) {
            vm.prank(governorAddress);
            mintController.setAfterMintHook(address(this));
        }

        vm.startPrank(alice);
        usdc.approve(address(gateway), _mintAmount);
        uint256 receiptAmount = gateway.mint(alice, _mintAmount);
        vm.stopPrank();
        uint256 expectedReceiptAmount = _mintAmount * 1e12 * 1e18 / IUSD_ORACLE_PRICE; // account for decimal correction and oracle price
        assertEq(
            receiptAmount,
            expectedReceiptAmount,
            "Error: mintController.mint() does not return the correct amount of receipt"
        );
        assertEq(
            iusd.balanceOf(alice),
            expectedReceiptAmount,
            "Error: Alice's iUSD balance does not match the expected receipt amount"
        );
        assertEq(
            usdc.balanceOf(address(mintController)),
            _mintAmount,
            "Error: mintController does not have the correct amount of USDC"
        );
        assertEq(
            afterMintHookCalled, _setupAfterMintHook, "Error: mintController.mint() does not call the afterMintHook"
        );
    }

    function testMintAndStakeShouldRevertIfPaused() public {
        vm.prank(guardianAddress);
        mintController.pause();

        usdc.mint(address(this), 100e6);
        usdc.approve(address(gateway), 100e6);

        vm.expectRevert(abi.encodeWithSelector(Pausable.EnforcedPause.selector));
        gateway.mintAndStake(address(this), 100e6);
    }

    function testMintAndStakeShouldRevertIfAssetAmountIsLessThanMinMintAmount(uint256 _mintAmount) public {
        _mintAmount = bound(_mintAmount, 1, 1_000_000e6);
        vm.prank(governorAddress);
        mintController.setMinMintAmount(_mintAmount + 1);

        usdc.mint(address(this), _mintAmount);
        usdc.approve(address(gateway), _mintAmount);

        vm.expectRevert(abi.encodeWithSelector(IMintController.MintAmountTooLow.selector, _mintAmount, _mintAmount + 1));
        gateway.mintAndStake(address(this), _mintAmount);
    }

    function testMintAndStake(uint256 _mintAmount) public {
        _mintAmount = bound(_mintAmount, 1e6, 1_000_000_000e6);
        // give _mintAmount USDC to alice
        usdc.mint(address(alice), _mintAmount);

        vm.startPrank(alice);
        usdc.approve(address(gateway), _mintAmount);
        uint256 receiptAmount = gateway.mintAndStake(alice, _mintAmount);
        vm.stopPrank();
        uint256 expectedReceiptAmount = _mintAmount * 1e12 * 1e18 / IUSD_ORACLE_PRICE; // account for decimal correction and oracle price
        assertEq(
            receiptAmount,
            expectedReceiptAmount,
            "Error: gateway.mintAndStake() does not return the correct amount of receipt"
        );
        assertEq(iusd.balanceOf(alice), 0, "Error: Alice's iUSD balance should be 0");
        assertEq(
            siusd.balanceOf(alice),
            expectedReceiptAmount,
            "Error: Alice's sUSD balance does not match the expected receipt amount"
        );
        assertEq(
            siusd.totalAssets(),
            expectedReceiptAmount,
            "Error: sUSD total assets do not match the expected receipt amount"
        );
        assertEq(iusd.balanceOf(address(mintController)), 0, "Error: mintController's iUSD balance should be 0");
        assertEq(
            iusd.balanceOf(address(siusd)),
            expectedReceiptAmount,
            "Error: sUSD's iUSD balance does not match the expected receipt amount"
        );
    }

    function testRedeemWhenPaused() public {
        vm.prank(guardianAddress);
        redeemController.pause();

        vm.prank(address(mintController));
        iusd.mint(address(this), 100e18);
        iusd.approve(address(gateway), 100e18);

        vm.expectRevert(abi.encodeWithSelector(Pausable.EnforcedPause.selector));
        gateway.redeem(address(this), 100e18);
    }

    function testRedeemWhenAmountTooLowShouldRevert(uint256 _redeemAmount) public {
        _redeemAmount = bound(_redeemAmount, 1, 1_000_000e6);
        vm.prank(governorAddress);
        redeemController.setMinRedemptionAmount(_redeemAmount + 1);

        vm.prank(address(mintController));
        iusd.mint(address(this), _redeemAmount);
        iusd.approve(address(gateway), _redeemAmount);

        vm.expectRevert(
            abi.encodeWithSelector(IRedeemController.RedeemAmountTooLow.selector, _redeemAmount, _redeemAmount + 1)
        );
        gateway.redeem(address(this), _redeemAmount);
    }

    /// @notice mint 1000 iUSD and then redeem 500 iUSD
    /// THIS TEST SHOULD FAIL ONCE WE IMPLEMENT MINT + REDEEM RESTRICTION IN THE SAME BLOCK
    /// to fix it then: just warp a bit in the future after the mint, so that the redeem can be processed
    function testRedeemWithEnoughLiquidityShouldSendDirectly(bool _setupBeforeRedeemHook) public {
        usdc.mint(address(alice), 1000e6);

        if (_setupBeforeRedeemHook) {
            vm.prank(governorAddress);
            redeemController.setBeforeRedeemHook(address(this));
        }

        vm.startPrank(alice);
        usdc.approve(address(gateway), 1000e6);
        gateway.mint(alice, 1000e6);
        vm.stopPrank();

        // skip for next block given restriction on mint and redemption on same block
        vm.warp(block.timestamp + 1);

        // move funds from mintController to redeemController
        vm.startPrank(farmManagerAddress);
        mintController.withdraw(usdc.balanceOf(address(mintController)), address(redeemController));
        vm.stopPrank();

        // redeem 500 iUSD
        vm.startPrank(alice);
        iusd.approve(address(gateway), 500e18);
        uint256 expectedAssetAmount = 500e6 * IUSD_ORACLE_PRICE / 1e18;
        uint256 assetAmount = gateway.redeem(alice, 500e18);
        vm.stopPrank();
        assertEq(
            assetAmount, expectedAssetAmount, "Error: gateway.redeem() does not return the correct amount of asset"
        );
        assertEq(usdc.balanceOf(alice), expectedAssetAmount, "Error: Alice does not have the correct amount of USDC");
        assertEq(
            beforeRedeemHookCalled,
            _setupBeforeRedeemHook,
            "Error: redeemController.redeem() does not call the beforeRedeemHook"
        );
    }

    function testRedeemWithNotEnoughLiquidityShouldEnqueue() public {
        scenarioAliceMintWith1000USDCAndHalfIsAllocatedToFarm();

        // move funds from mintController to redeemController
        vm.startPrank(farmManagerAddress);
        mintController.withdraw(usdc.balanceOf(address(mintController)), address(redeemController));
        vm.stopPrank();

        uint256 iusdTotalSupplyBefore = iusd.totalSupply();
        scenarioAliceRedeemsAllHerIUSD();

        // after the redeem, alice should have received 500 USDC
        assertEq(usdc.balanceOf(alice), 500e6, "Error: Alice does not have the correct amount of USDC");
        // and the redeemController should have burned 500 / IUSD_ORACLE_PRICE iUSD
        // meaning that the total supply of iUSD should be reduced by 500 / IUSD_ORACLE_PRICE
        assertEq(iusd.totalSupply(), iusdTotalSupplyBefore - 500e18 * 1e18 / IUSD_ORACLE_PRICE);
        // balance of redeemController should be 0 USDC
        assertEq(
            usdc.balanceOf(address(redeemController)),
            0,
            "Error: redeemController does not have the correct amount of USDC"
        );
        // there should be a ticket in the queue for the remaining iUSD
        assertEq(
            redeemController.queueLength(), 1, "Error: There should be 1 ticket in the queue for the remaining iUSD"
        );
        // total enqueued redemptions should be 500 / IUSD_ORACLE_PRICE iUSD
        assertEq(
            redeemController.totalEnqueuedRedemptions(),
            500e18 * 1e18 / IUSD_ORACLE_PRICE,
            "Error: Total enqueued redemptions should be 500 / IUSD_ORACLE_PRICE iUSD"
        );
    }

    function testClaimRedemption() public {
        scenarioAliceMintWith1000USDCAndHalfIsAllocatedToFarm();

        // move funds from mintController to redeemController
        vm.startPrank(farmManagerAddress);
        mintController.withdraw(usdc.balanceOf(address(mintController)), address(redeemController));
        vm.stopPrank();

        scenarioAliceRedeemsAllHerIUSD();

        // here, alice is enqueued and should receive USDC when some usdc are deposited
        // to simulate that, we deposit 1000 USDC to the redeemController
        usdc.mint(address(redeemController), 1000e6);
        // and we call the deposit function as the farm manager
        vm.prank(farmManagerAddress);
        redeemController.deposit();

        // usdc balance of the redeemController should be 1000 USDC
        // but assets() should be 500 USDC because of the current pending claims made available by the deposit function
        assertEq(
            usdc.balanceOf(address(redeemController)),
            1000e6,
            "Error: redeemController does not have the correct amount of USDC after deposit"
        );
        assertEq(redeemController.assets(), 500e6, "Error: redeemController does not have the correct amount of assets");
        assertEq(
            redeemController.totalPendingClaims(),
            500e6,
            "Error: redeemController does not have the correct amount of total pending claims"
        );

        // the remaining iUSD should have been burned
        assertEq(iusd.totalSupply(), 0, "Error: iUSD total supply should be 0");

        // alice should be entitled to claim 500
        assertEq(
            redeemController.userPendingClaims(alice),
            500e6,
            "Error: Alice does not have the correct amount of pending claims"
        );

        uint256 aliceUsdcBalanceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        gateway.claimRedemption();

        // now alice should have received 500 USDC (when she had already)
        assertEq(
            usdc.balanceOf(alice),
            aliceUsdcBalanceBefore + 500e6,
            "Error: Alice does not have the correct amount of USDC after claiming redemption"
        );
        // and the redeemController should have 500 USDC (1000 where deposited, 500 where sent to alice)
        assertEq(
            usdc.balanceOf(address(redeemController)),
            500e6,
            "Error: redeemController does not have the correct amount of USDC after claiming redemption"
        );
        // and the total enqueued redemptions should be 0
        assertEq(redeemController.totalEnqueuedRedemptions(), 0, "Error: Total enqueued redemptions should be 0");
        assertEq(redeemController.totalPendingClaims(), 0, "Error: Total pending claims should be 0");
        // and the queue should be empty
        assertEq(redeemController.queueLength(), 0, "Error: Queue should be empty");
    }

    function testWithdraw() public {
        usdc.mint(address(mintController), 1000e6);
        vm.prank(farmManagerAddress);
        mintController.withdraw(1000e6, address(this));
        assertEq(
            usdc.balanceOf(address(this)),
            1000e6,
            "Error: address(this) does not have the correct amount of USDC after withdrawing"
        );

        usdc.mint(address(redeemController), 1000e6);
        vm.prank(farmManagerAddress);
        redeemController.withdraw(1000e6, address(this));
        assertEq(
            usdc.balanceOf(address(this)),
            2000e6,
            "Error: address(this) does not have the correct amount of USDC after withdrawing"
        );
    }

    function testMintAndRedeemCannotBeDoneInSameBlock() public {
        deal(address(usdc), address(this), 1000e6);
        vm.prank(governorAddress);
        mintController.setRestrictionDuration(1 days);
        usdc.approve(address(gateway), 1000e6);
        uint256 receiptAmount = gateway.mint(address(this), 1000e6);
        iusd.approve(address(gateway), receiptAmount);
        vm.expectRevert(
            abi.encodeWithSelector(ActionRestriction.ActionRestricted.selector, address(this), block.timestamp + 1 days)
        );
        gateway.redeem(address(this), receiptAmount);
    }
}

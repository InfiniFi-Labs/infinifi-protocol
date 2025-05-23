// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "@forge-std/console.sol";
import {Fixture} from "@test/Fixture.t.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {MockERC20} from "@test/mock/MockERC20.sol";
import {MockSwapRouter} from "@test/mock/MockSwapRouter.sol";
import {IMintController} from "@interfaces/IMintController.sol";
import {IRedeemController} from "@interfaces/IRedeemController.sol";
import {FixedPointMathLib} from "@solmate/src/utils/FixedPointMathLib.sol";
import {InfiniFiGatewayV1} from "@gateway/InfiniFiGatewayV1.sol";

contract MintRedeemControllerUnitTest is Fixture {
    using FixedPointMathLib for uint256;

    bool public afterMintHookCalled = false;
    bool public beforeRedeemHookCalled = false;

    // mint & redeem hooks
    function afterMint(address, uint256) external {
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

        // deploy 500 (half) of USDC to a farm
        vm.startPrank(farmManagerAddress);
        {
            mintController.withdraw(500e6, address(farm1));
            farm1.deposit();
        }
        vm.stopPrank();

        // now only 500 USDC are left in the contract while alice still has 1000 iUSD
        assertEq(usdc.balanceOf(address(mintController)), 500e6);
    }

    function scenarioAliceRedeemsAllHerIUSD() private {
        // alice will try to redeem all her iUSD
        vm.startPrank(alice);
        iusd.approve(address(gateway), iusd.balanceOf(alice));
        gateway.redeem(alice, iusd.balanceOf(alice), 0);
        vm.stopPrank();
    }

    function testInitialState() public view {
        // check contructor setup & default values for state variables
        assertEq(mintController.receiptToken(), address(iusd), "Error: mintController.receiptToken() should be iUSD");
        assertEq(mintController.assetToken(), address(usdc), "Error: mintController.assetToken() should be USDC");
        assertEq(
            mintController.accounting(), address(accounting), "Error: mintController.accounting() should be accounting"
        );
        assertEq(mintController.minAssetAmount(), 1, "Error: mintController.minAssetAmount() should be 1");
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
        vm.prank(parametersAddress);
        vm.expectRevert(abi.encodeWithSelector(IRedeemController.RedeemAmountTooLow.selector, 0, 1));
        redeemController.setMinRedemptionAmount(0);
    }

    function testSetMinRedemptionCanBeSetByGovernor(uint256 _amount) public {
        _amount = bound(_amount, 1, 1_000e18);
        assertEq(redeemController.minRedemptionAmount(), 1, "Error: redeemController.minRedemptionAmount() should be 1");
        vm.prank(parametersAddress);
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

    function testSetMinAssetAmountShouldErrorIfNotGovernor() public {
        vm.expectRevert("UNAUTHORIZED");
        mintController.setMinAssetAmount(100);
    }

    function testSetMinAssetAmountCanBeSetByGovernor(uint256 _amount) public {
        _amount = bound(_amount, 1, 1_000e18);
        assertEq(mintController.minAssetAmount(), 1, "Error: mintController.minAssetAmount() should be 1 at default");
        vm.prank(parametersAddress);
        mintController.setMinAssetAmount(_amount);
        assertEq(
            mintController.minAssetAmount(),
            _amount,
            "Error: mintController.minAssetAmount() should be set to _amount after calling setMinAssetAmount()"
        );
    }

    function testSetMinAssetAmountCannotBeZero() public {
        assertEq(mintController.minAssetAmount(), 1, "Error: mintController.minAssetAmount() should be 1 at default");
        vm.prank(parametersAddress);
        vm.expectRevert(abi.encodeWithSelector(IMintController.AssetAmountTooLow.selector, 0, 1));
        mintController.setMinAssetAmount(0);
    }

    function testAssetToReceipt() public {
        vm.prank(oracleManagerAddress);
        oracleIusd.setPrice(1e18);

        assertEq(mintController.assetToReceipt(500e6), 500e18);

        vm.prank(oracleManagerAddress);
        oracleIusd.setPrice(0.5e18);

        assertEq(mintController.assetToReceipt(500e6), 1000e18);
    }

    function testReceiptToAsset() public {
        vm.prank(oracleManagerAddress);
        oracleIusd.setPrice(1e18);

        assertEq(redeemController.receiptToAsset(500e18), 500e6);

        vm.prank(oracleManagerAddress);
        oracleIusd.setPrice(0.5e18);

        assertEq(redeemController.receiptToAsset(1000e18), 500e6);
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

    function testMintShouldRevertIfAssetAmountIsLessThanMinAssetAmount(uint256 _mintAmount) public {
        _mintAmount = bound(_mintAmount, 1, 1_000_000e6);
        vm.prank(parametersAddress);
        mintController.setMinAssetAmount(_mintAmount + 1);

        usdc.mint(address(this), _mintAmount);
        usdc.approve(address(gateway), _mintAmount);

        vm.expectRevert(
            abi.encodeWithSelector(IMintController.AssetAmountTooLow.selector, _mintAmount, _mintAmount + 1)
        );
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
        vm.prank(parametersAddress);
        mintController.setMinAssetAmount(_mintAmount + 1);

        usdc.mint(address(this), _mintAmount);
        usdc.approve(address(gateway), _mintAmount);

        vm.expectRevert(
            abi.encodeWithSelector(IMintController.AssetAmountTooLow.selector, _mintAmount, _mintAmount + 1)
        );
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

        _mintBackedReceiptTokens(address(this), 100e18);
        iusd.approve(address(gateway), 100e18);

        vm.expectRevert(abi.encodeWithSelector(Pausable.EnforcedPause.selector));
        gateway.redeem(address(this), 100e18, 0);
    }

    function testRedeemWhenAmountTooLowShouldRevert(uint256 _redeemAmount) public {
        _redeemAmount = bound(_redeemAmount, 1, 1_000_000e6);
        vm.prank(parametersAddress);
        redeemController.setMinRedemptionAmount(_redeemAmount + 1);

        _mintBackedReceiptTokens(address(this), _redeemAmount);
        iusd.approve(address(gateway), _redeemAmount);

        vm.expectRevert(
            abi.encodeWithSelector(IRedeemController.RedeemAmountTooLow.selector, _redeemAmount, _redeemAmount + 1)
        );
        gateway.redeem(address(this), _redeemAmount, 0);
    }

    /// @notice mint 1000 iUSD and then redeem 500 iUSD
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

        // move funds from mintController to redeemController
        vm.startPrank(farmManagerAddress);
        mintController.withdraw(usdc.balanceOf(address(mintController)), address(redeemController));
        vm.stopPrank();

        // redeem 500 iUSD
        vm.startPrank(alice);
        iusd.approve(address(gateway), 500e18);
        uint256 expectedAssetAmount = 500e6 * IUSD_ORACLE_PRICE / 1e18;
        uint256 assetAmount = gateway.redeem(alice, 500e18, 0);
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

    function testRedeemMinAssetsOut() public {
        scenarioAliceMintWith1000USDCAndHalfIsAllocatedToFarm();

        // move funds from mintController to redeemController
        vm.startPrank(farmManagerAddress);
        mintController.withdraw(usdc.balanceOf(address(mintController)), address(redeemController));
        vm.stopPrank();

        assertEq(usdc.balanceOf(address(redeemController)), 500e6);

        // alice tries to redeem all her iusd, but it fails because only 500e6
        // liquidity is available
        uint256 aliceIusdBalance = iusd.balanceOf(alice);
        vm.startPrank(alice);
        {
            iusd.approve(address(gateway), aliceIusdBalance);
            vm.expectRevert(abi.encodeWithSelector(InfiniFiGatewayV1.MinAssetsOutError.selector, 500e6 + 1, 500e6));
            gateway.redeem(alice, aliceIusdBalance, 500e6 + 1);
        }
        vm.stopPrank();
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

    function testMintRedeem_RedeemNotProducingMoreThanDepositedInvariant(uint256 _assetIn, uint256 _price) public {
        _assetIn = bound(_assetIn, 1e6, 1_000_000e6);
        _price = bound(_price, 0.1e18, 1e18);

        vm.prank(oracleManagerAddress);
        oracleIusd.setPrice(_price);

        dealToken(address(usdc), address(alice), _assetIn);
        vm.startPrank(alice);
        {
            usdc.approve(address(gateway), _assetIn);
            gateway.mint(alice, _assetIn);
        }
        vm.stopPrank();

        vm.prank(msig);
        manualRebalancer.singleMovement(address(mintController), address(redeemController), _assetIn);

        vm.startPrank(alice);
        {
            iusd.approve(address(gateway), type(uint256).max);
            uint256 aliceBalance = iusd.balanceOf(alice);

            gateway.redeem(alice, aliceBalance, 0);
        }

        uint256 usdcBalance = usdc.balanceOf(alice);

        assertGe(_assetIn, usdcBalance, "Redeeming more than deposited");
        assertApproxEqAbs(usdcBalance, _assetIn, 10e6, "User is suffering more losses than allowed");
    }

    // Certora finding
    function testMintRedeem_SolvencyInvariant() public {
        uint256 _assetIn = 0.900003e6;
        uint256 _price = 0.9e18 + 1;
        uint256 totalSupply = 1000003333333333332;

        vm.prank(oracleManagerAddress);
        oracleIusd.setPrice(_price);

        dealToken(address(usdc), address(redeemController), _assetIn);

        vm.prank(governorAddress);
        redeemController.setBeforeRedeemHook(address(0));

        vm.prank(address(mintController));
        iusd.mint(address(this), totalSupply);

        iusd.approve(address(gateway), type(uint256).max);
        gateway.redeem(address(this), 1e18, 0);

        uint256 assetValue = accounting.totalAssetsValue();
        assertLe(iusd.totalSupply() * _price, assetValue * 1e18, "iUSD is overcollateralized");
    }

    function testMintRedeem_SolvencyInvariantBroken2() public {
        uint256 iusdPrice = 0.900000000000000111e18;

        uint256 redeemControllerUSDC = 0.900002e6;
        uint256 iusdTotalSupply = 1.000002222222222095e18;
        uint256 redeemAmount = 1.000001111109876545e18;

        vm.prank(oracleManagerAddress);
        oracleIusd.setPrice(iusdPrice);

        dealToken(address(usdc), address(redeemController), redeemControllerUSDC);

        vm.prank(governorAddress);
        redeemController.setBeforeRedeemHook(address(0));

        vm.prank(address(mintController));
        iusd.mint(address(this), iusdTotalSupply);

        iusd.approve(address(gateway), type(uint256).max);
        gateway.redeem(address(this), redeemAmount, 0);

        uint256 usdcBalance = accounting.totalAssetsValue();

        assertLe(iusd.totalSupply() * iusdPrice, usdcBalance * 1e18);
    }

    function testZapIn() public {
        MockSwapRouter router = new MockSwapRouter();
        MockERC20 weth = new MockERC20("Wrapped Ether", "WETH");

        vm.prank(parametersAddress);
        gateway.setEnabledRouter(address(router), true);

        router.mockPrepareSwap(address(weth), address(usdc), 1 ether, 2000e6);
        weth.mint(carol, 1 ether);

        vm.startPrank(carol);
        {
            weth.approve(address(gateway), 2 ether);
            gateway.zapIn(
                address(weth), 1 ether, address(router), abi.encodeWithSelector(MockSwapRouter.swap.selector), carol
            );
        }
        vm.stopPrank();

        assertEq(iusd.balanceOf(carol), 2500e18); // oracle price is 0.8$
    }
}

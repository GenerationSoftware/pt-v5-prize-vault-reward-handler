// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";

import { PrizeVaultRewardHandler, TwabRewards, IERC20, PrizeVault } from "../src/PrizeVaultRewardHandler.sol";
import { ERC20Mock } from "../lib/pt-v5-vault/lib/openzeppelin-contracts/contracts/mocks/ERC20Mock.sol";

contract PrizeVaultRewardHandlerTest is Test {

    event TokensDistributed(
        address indexed token,
        address indexed caller,
        uint256 indexed promotionId,
        uint256 startTime,
        uint256 endTime,
        uint256 amount
    );

    uint256 forkBlock = 20461315;
    uint256 forkTimestamp = 1727711977;
    string public constant forkNetwork = "base";

    ERC20Mock public rewardToken;
    PrizeVault public prizeVault = PrizeVault(address(0x4E42f783db2D0C5bDFf40fDc66FCAe8b1Cda4a43));
    TwabRewards public twabRewards = TwabRewards(address(0x86f0923d20810441efC593EB0F2825C6BfF2DC09));
    PrizeVaultRewardHandler public rewardHandler;
    uint256 public minDistributionSpacing = 1 days;

    function setUp() public {
        vm.createSelectFork(forkNetwork, forkBlock);
        vm.warp(forkTimestamp);
        rewardToken = new ERC20Mock();
        rewardHandler = new PrizeVaultRewardHandler(twabRewards, prizeVault, minDistributionSpacing);
    }

    function testConstructor() external {
        rewardHandler = new PrizeVaultRewardHandler(twabRewards, prizeVault, minDistributionSpacing);
        assertEq(address(rewardHandler.twabRewards()), address(twabRewards));
        assertEq(address(rewardHandler.prizeVault()), address(prizeVault));
        assertEq(rewardHandler.minDistributionSpacing(), minDistributionSpacing);
        assertEq(rewardHandler.maxDistributionTimeSpan(), uint256(1 days) * 91); // draw period times GP period in draws (TWAB is guaranteed to have history up to this time)
    }

    function testConstructor_MinSpacingExceedsMaxTimeSpan() external {
        vm.expectRevert(abi.encodeWithSelector(PrizeVaultRewardHandler.MinSpacingExceedsMaxTimeSpan.selector, uint256(1 days) * 91 + 1, uint256(1 days) * 91));
        new PrizeVaultRewardHandler(twabRewards, prizeVault, uint256(1 days) * 91 + 1);
    }

    function testConstructor_TwabControllerMismatch() external {
        vm.mockCall(address(prizeVault), abi.encodeWithSignature("twabController()"), abi.encode(address(this)));
        vm.expectRevert(PrizeVaultRewardHandler.TwabControllerMismatch.selector);
        new PrizeVaultRewardHandler(twabRewards, prizeVault, minDistributionSpacing);
    }

    function testDistributeTokens() external {
        rewardToken.mint(address(rewardHandler), 1e18);

        uint256 promotionId = 19;
        uint256 startTime = uint256(1719846000);
        uint256 endTime = uint256(1727708400);

        vm.expectEmit();
        emit TokensDistributed(
            address(rewardToken),
            address(this),
            promotionId,
            startTime,
            endTime,
            uint256(1e18)
        );
        rewardHandler.distributeTokens(address(rewardToken));

        assertEq(rewardToken.balanceOf(address(rewardHandler)), 0);
        assertEq(rewardToken.balanceOf(address(twabRewards)), 1e18);
        assertEq(twabRewards.getPromotion(promotionId).startTimestamp, startTime);
        assertEq(address(twabRewards.getPromotion(promotionId).token), address(rewardToken));
        assertEq(twabRewards.getPromotion(promotionId).vault, address(prizeVault));
        assertEq(uint256(twabRewards.getPromotion(promotionId).tokensPerEpoch), uint256(1e18));
        assertEq(uint256(twabRewards.getPromotion(promotionId).rewardsUnclaimed), uint256(1e18));
        assertEq(uint256(twabRewards.getPromotion(promotionId).numberOfEpochs), uint256(1));
        assertEq(uint256(twabRewards.getPromotion(promotionId).epochDuration), endTime - startTime);
        assertEq(twabRewards.getPromotion(promotionId).creator, address(rewardHandler));
        assertEq(rewardHandler.lastDistribution(address(rewardToken)), uint256(endTime));

        // send some more tokens in
        rewardToken.mint(address(rewardHandler), 2e18);

        // fails if we try again right away
        vm.expectRevert(abi.encodeWithSelector(PrizeVaultRewardHandler.DistributionTooSoon.selector, 0, minDistributionSpacing));
        rewardHandler.distributeTokens(address(rewardToken));

        // fails if we try again a second before min spacing since last
        vm.warp(endTime + minDistributionSpacing - 1);
        vm.expectRevert(abi.encodeWithSelector(PrizeVaultRewardHandler.DistributionTooSoon.selector, 82800, minDistributionSpacing));
        rewardHandler.distributeTokens(address(rewardToken));

        // fails if we try at exactly min spacing (because of the TWAB `periodEndOnOrAfter` function)
        vm.warp(endTime + minDistributionSpacing);
        vm.expectRevert(abi.encodeWithSelector(PrizeVaultRewardHandler.DistributionTooSoon.selector, 82800, minDistributionSpacing));
        rewardHandler.distributeTokens(address(rewardToken));

        // succeeds if we are 1 second into the next TWAB period
        vm.warp(endTime + minDistributionSpacing + 1);
        vm.expectEmit();
        emit TokensDistributed(
            address(rewardToken),
            address(this),
            promotionId + 1,
            endTime, // last end time
            endTime + 1 days, // new end time
            uint256(2e18)
        );
        rewardHandler.distributeTokens(address(rewardToken));
        assertEq(rewardHandler.lastDistribution(address(rewardToken)), uint256(endTime + 1 days));

        // try to start another with no tokens
        vm.warp(endTime + minDistributionSpacing * 2 + 1);
        vm.expectRevert(abi.encodeWithSignature("ZeroTokensPerEpoch()"));
        rewardHandler.distributeTokens(address(rewardToken));
    }

    function testDestroyPromotionAfterGracePeriod() external {
        rewardToken.mint(address(rewardHandler), 1e18);
        uint256 promotionId = 19;
        rewardHandler.distributeTokens(address(rewardToken));

        assertEq(rewardToken.balanceOf(address(this)), 0);
        assertEq(rewardToken.balanceOf(address(twabRewards)), 1e18);

        // Destroy promotion using owner calls
        vm.warp(block.timestamp + 1 days * 365);
        vm.startPrank(prizeVault.owner());
        PrizeVaultRewardHandler.Call[] memory calls = new PrizeVaultRewardHandler.Call[](1);
        calls[0] = PrizeVaultRewardHandler.Call({
            to: address(twabRewards),
            data: abi.encodeWithSelector(TwabRewards.destroyPromotion.selector, promotionId, address(this)),
            value: uint256(0)
        });
        rewardHandler.ownerCalls(calls);
        vm.stopPrank();

        assertEq(rewardToken.balanceOf(address(this)), 1e18);
        assertEq(rewardToken.balanceOf(address(twabRewards)), 0);
    }

    function testOwnerCallsNotOwner() external {
        PrizeVaultRewardHandler.Call[] memory calls = new PrizeVaultRewardHandler.Call[](0);
        vm.expectRevert(abi.encodeWithSelector(PrizeVaultRewardHandler.SenderNotPrizeVaultOwner.selector, address(this), prizeVault.owner()));
        rewardHandler.ownerCalls(calls);
    }
}

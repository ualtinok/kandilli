// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.11;

import {DSTest} from "ds-test/test.sol";
import {Utilities} from "./utils/Utilities.sol";
import {console} from "./utils/Console.sol";
import {Hevm} from "./utils/Hevm.sol";
import {Kandilli} from "../Kandilli.sol";
import {MockAuctionableToken} from "./mocks/MockAuctionableToken.sol";
import {WETH} from "./mocks/WETH.sol";
import {LinkTokenMock} from "./mocks/LinkTokenMock.sol";
import {VRFCoordinatorMock} from "chainlink/v0.8/mocks/VRFCoordinatorMock.sol";
import {IKandilli} from "../interfaces/IKandilli.sol";
import "../../lib/openzeppelin-contracts/contracts/mocks/SafeERC20Helper.sol";

contract KandilliTest is DSTest {
    Hevm internal immutable vm = Hevm(HEVM_ADDRESS);

    Utilities internal utils;
    Kandilli internal kandilli;
    MockAuctionableToken internal mockAuctionableToken;
    LinkTokenMock internal linkToken;
    VRFCoordinatorMock internal vrfCoordinatorMock;
    WETH internal weth;

    address payable[] internal users;

    uint64 internal winnersProposalDeposit = (1 ether) / (1 gwei); // 1 ether
    uint32 internal numWinners = 64; // 64 users
    uint32 internal auctionTotalDuration = 259200; // 3 days
    uint32 internal fraudChallengePeriod = 10800; // 3 hours
    uint32 internal retroSnuffGasCost = 400_000; // 200k gas
    uint32 internal postWinnerGasCost = 500_000; // 200k gas
    uint64 internal initialTargetBaseFee = 100 gwei; // 3 hours
    uint64 internal vrfFee = 100_000;
    uint256 internal randomE = 518947192038190283;
    uint8 internal maxBountyMultiplier = 10;
    uint8 internal snuffPercentage = 30;

    struct KandilBidWithIndex {
        address payable bidder; // address of the bidder
        uint32 timePassedFromStart; // time passed from startTime
        uint64 bidAmount; // bid value in gwei
        bool isClaimed;
        uint256 index;
    }

    function setUp() public {
        utils = new Utilities();
        users = utils.createUsers(100);
        mockAuctionableToken = new MockAuctionableToken();
        // Give users[0] link tokens
        linkToken = new LinkTokenMock("LinkToken", "LINK", users[0], 5e18);
        vrfCoordinatorMock = new VRFCoordinatorMock(address(linkToken));
        weth = new WETH();
        IKandilli.KandilHouseSettings memory settings = IKandilli.KandilHouseSettings(
            winnersProposalDeposit,
            fraudChallengePeriod,
            retroSnuffGasCost,
            postWinnerGasCost,
            auctionTotalDuration,
            numWinners,
            maxBountyMultiplier,
            snuffPercentage,
            true
        );
        uint32[] memory initialBidAmounts = new uint32[](10);
        for (uint256 i = 0; i < 10; i++) {
            initialBidAmounts[i] = 100;
        }
        kandilli = new Kandilli(
            mockAuctionableToken,
            settings,
            initialBidAmounts,
            address(weth),
            address(linkToken),
            address(vrfCoordinatorMock),
            vrfFee
        );
    }

    function testBid() public {
        kandilli.init();
        uint256 auctionId = 1;
        uint256 startTime = kandilli.getAuctionStartTime(auctionId);
        address payable alice = users[0];
        address payable bob = users[1];
        vm.prank(alice);
        kandilli.addBidToAuction{value: 1 ether}(auctionId);
        vm.prank(bob);
        kandilli.addBidToAuction{value: 1 ether}(auctionId);

        // Fail if auction doesn't exist
        vm.expectRevert(abi.encodeWithSignature("AuctionIsNotRunning()"));
        kandilli.addBidToAuction{value: 1 ether}(99);

        // Fail if lower then gwei precision bid
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("BidWithPrecisionLowerThanGwei()"));
        kandilli.addBidToAuction{value: 1 wei}(auctionId);

        vm.prank(alice);
        console.log("StartTime: ", startTime);
        vm.warp(startTime + auctionTotalDuration + 1);
        vm.expectRevert(abi.encodeWithSignature("CannotBidAfterAuctionEndTime()"));
        kandilli.addBidToAuction{value: 1 ether}(auctionId);

        uint256 minBid = kandilli.getAuctionMinimumBidAmount(auctionId);
        console.log(minBid);
    }

    function testIncreaseBid() public {
        kandilli.init();
        uint256 auctionId = 1;
        address payable alice = users[0];
        address payable bob = users[1];

        // Send dummy bids first to clutter.
        _sendBids(auctionId, 20);

        vm.startPrank(alice);
        uint256 aliceOldBalance = alice.balance;
        uint256 bidId = kandilli.addBidToAuction{value: 1 ether}(auctionId);
        kandilli.increaseAmountOfBid{value: 1 ether}(auctionId, bidId);
        uint256 aliceNewBalance = alice.balance;

        assertEq(aliceOldBalance - aliceNewBalance, 2 ether);

        IKandilli.KandilBid[] memory bids = kandilli.getAuctionBids(auctionId);

        // Bid amount is in gwei inside KandilBid struct
        assertEq(bids[bidId].bidAmount * (1 gwei), 2 ether);

        // Fail when try to increase someone else's bid
        vm.startPrank(bob);
        vm.expectRevert(abi.encodeWithSignature("CannotIncreaseBidForNonOwnedBid()"));
        kandilli.increaseAmountOfBid{value: 1 ether}(auctionId, bidId);
    }

    function testSnuffCandle(
        uint256 r,
        uint16 timePassed,
        bool isLinkRequired
    ) public {
        kandilli.setAuctionRequiresLink(isLinkRequired);
        kandilli.init();
        uint256 auctionId = 1;
        address payable alice = users[0];
        address payable bob = users[1];

        uint256 startTime = kandilli.getAuctionStartTime(auctionId);
        _sendBids(auctionId, 20);

        vm.expectRevert(abi.encodeWithSignature("CannotSnuffCandleBeforeDefiniteEndTime()"));
        kandilli.retroSnuffCandle(1);

        vm.expectRevert(abi.encodeWithSignature("CannotSnuffCandleForNotRunningAuction()"));
        kandilli.retroSnuffCandle(99);

        uint256 aliceOldBalance = alice.balance;
        vm.warp(startTime + auctionTotalDuration + timePassed);
        uint256 bounty = kandilli.getAuctionRetroSnuffBounty(auctionId);
        uint256 multiplier = timePassed / 24 > maxBountyMultiplier ? maxBountyMultiplier : (timePassed / 24) + 1;

        assertEq(bounty, retroSnuffGasCost * multiplier * 100 * (1 gwei));

        if (isLinkRequired) {
            vm.prank(bob);
            vm.expectRevert(abi.encodeWithSignature("UserDontHaveEnoughLinkToAskForVRF()"));
            kandilli.retroSnuffCandle(auctionId);

            vm.startPrank(alice);
            vm.expectRevert("ERC20: transfer amount exceeds allowance");
            kandilli.retroSnuffCandle(auctionId);
        }

        {
            vm.startPrank(alice);
            if (isLinkRequired) {
                linkToken.approve(address(kandilli), vrfFee);
            } else {
                // Only alice (users[0]) have link tokens.
                linkToken.transfer(address(kandilli), vrfFee);
            }
            bytes32 requestId = kandilli.retroSnuffCandle(auctionId);
            vrfCoordinatorMock.callBackWithRandomness(requestId, r, address(kandilli));
            uint256 aliceNewBalance = alice.balance;
            assertEq(aliceNewBalance - aliceOldBalance, bounty);
            vm.stopPrank();
        }

        {
            uint256 snuffTime = kandilli.getAuctionCandleSnuffedTime(auctionId);
            uint256 endTime = kandilli.getAuctionDefiniteEndTime(auctionId);
            uint256 snuffPercentage = kandilli.getAuctionSnuffPercentage(auctionId);
            uint256 snuffEarliestPossibleTime = endTime - (((endTime - startTime) * snuffPercentage) / 100);

            assertGt(snuffTime, startTime);
            assertLt(snuffTime, endTime);
            assertGe(snuffTime, snuffEarliestPossibleTime);
        }

        // Fail when trying to candle that's already snuffed
        vm.expectRevert(abi.encodeWithSignature("CannotSnuffCandleForNotRunningAuction()"));
        kandilli.retroSnuffCandle(auctionId);
    }

    function testPostWinners() public {
        kandilli.init();

        uint256 auctionId = 1;
        uint256 depositAmount = kandilli.getAuctionRequiredWinnersProposalDeposit(auctionId);
        uint256 startTime = kandilli.getAuctionStartTime(auctionId);

        // Fail when posting winners before candle snuffed
        {
            uint32[] memory dummyWinnerIds = new uint32[](3);
            bytes32 dummyHash = keccak256(abi.encodePacked("x"));

            dummyWinnerIds[0] = 3;
            dummyWinnerIds[1] = 3;
            dummyWinnerIds[2] = 3;
            vm.expectRevert(abi.encodeWithSignature("CannotPostWinnersBeforeVRFSetOrWhenWinnersAlreadyPosted()"));
            kandilli.postWinners{value: depositAmount}(auctionId, dummyWinnerIds, dummyHash);
        }

        _sendBids(auctionId, 100);
        _snuffCandle(auctionId, randomE, startTime);

        IKandilli.KandilBid[] memory bids = kandilli.getAuctionBids(auctionId);

        uint256 snuffTime = kandilli.getAuctionCandleSnuffedTime(auctionId);
        uint256 bidCount = 0;
        // Count bids sent before snuff time, in test env, time starts from 0 so no need to convert.
        for (uint256 i = 0; i < bids.length; i++) {
            if (bids[i].timePassedFromStart < snuffTime) {
                bidCount++;
            }
        }
        console.log("TotalBid", bids.length);
        console.log("BidCountBeforeSnuff", bidCount);
        //Bid with index to sort with for same amount and same timestamp bids.
        KandilBidWithIndex[] memory nBids = new KandilBidWithIndex[](bidCount);
        for (uint256 i = 0; i < bidCount; i++) {
            nBids[i] = KandilBidWithIndex(bids[i].bidder, bids[i].timePassedFromStart, bids[i].bidAmount, bids[i].isClaimed, i);
        }
        _quickSort(nBids, 0, nBids.length - 1);

        uint256 numWinners = kandilli.getAuctionWinnerCount(auctionId);
        uint256 vrfResult = kandilli.getAuctionVRF(auctionId);

        uint32[] memory winnerBidIds = new uint32[](numWinners);
        for (uint256 i = 0; i < numWinners; i++) {
            winnerBidIds[i] = uint32(nBids[i].index);
        }

        // Fail when posting winners with wrong hash
        vm.expectRevert(abi.encodeWithSignature("IncorrectHashForWinnerBids()"));
        kandilli.postWinners{value: depositAmount}(auctionId, winnerBidIds, keccak256(abi.encodePacked("x")));

        bytes32 hash = keccak256(abi.encodePacked(winnerBidIds, vrfResult));

        // Fail when posting winners with wrong deposit amount
        vm.expectRevert(abi.encodeWithSignature("DepositAmountForWinnersProposalNotMet()"));
        kandilli.postWinners{value: 1 wei}(auctionId, winnerBidIds, hash);

        // Succeed to post winners and check balance
        {
            address payable alice = users[0];
            uint256 aliceBalanceBefore = alice.balance;
            vm.prank(alice);
            kandilli.postWinners{value: depositAmount}(auctionId, winnerBidIds, hash);
            uint256 aliceBalanceAfter = alice.balance;
            assertEq(aliceBalanceBefore - aliceBalanceAfter, depositAmount);
        }

        // Fail when posting winners a second time
        {
            vm.expectRevert(abi.encodeWithSignature("CannotPostWinnersBeforeVRFSetOrWhenWinnersAlreadyPosted()"));
            kandilli.postWinners{value: depositAmount}(auctionId, winnerBidIds, hash);
        }
    }

    function testClaimToken() public {
        kandilli.init();

        uint256 auctionId = 1;
        uint256 startTime = kandilli.getAuctionStartTime(auctionId);

        _sendBids(auctionId, 100);

        IKandilli.KandilBid[] memory bids = kandilli.getAuctionBids(auctionId);

        _snuffCandle(auctionId, randomE, startTime);

        //Bid with index to sort with for same amount and same timestamp bids.
        KandilBidWithIndex[] memory nBids = new KandilBidWithIndex[](bids.length);
        for (uint256 i = 0; i < bids.length; i++) {
            nBids[i] = KandilBidWithIndex(bids[i].bidder, bids[i].timePassedFromStart, bids[i].bidAmount, bids[i].isClaimed, i);
        }
        _quickSort(nBids, 0, nBids.length - 1);

        uint256 numWinners = kandilli.getAuctionWinnerCount(auctionId);
        uint256 vrfResult = kandilli.getAuctionVRF(auctionId);
        uint256 depositAmount = kandilli.getAuctionRequiredWinnersProposalDeposit(auctionId);

        uint32[] memory winnerBidIds = new uint32[](numWinners);
        for (uint256 i = 0; i < numWinners; i++) {
            winnerBidIds[i] = uint32(nBids[i].index);
        }
        bytes32 hash = keccak256(abi.encodePacked(winnerBidIds, vrfResult));

        vm.expectRevert(abi.encodeWithSignature("CannotClaimAuctionItemBeforeWinnersPosted()"));

        kandilli.claimWinningBid(auctionId, winnerBidIds[0], hash, winnerBidIds, 0);

        kandilli.postWinners{value: depositAmount}(auctionId, winnerBidIds, hash);

        vm.expectRevert(abi.encodeWithSignature("CannotClaimAuctionItemBeforeChallengePeriodEnds()"));

        kandilli.claimWinningBid(auctionId, winnerBidIds[0], hash, winnerBidIds, 0);

        vm.warp(startTime + auctionTotalDuration + fraudChallengePeriod + 2);

        address payable alice = users[0];
        uint256 aliceBeforeBalance = alice.balance;
        vm.prank(alice);

        kandilli.claimWinningBid(auctionId, winnerBidIds[0], hash, winnerBidIds, 0);
        uint256 minBidForAuction = kandilli.getAuctionMinimumBidAmount(auctionId);

        // Check if alice received right bounty.
        assertEq(minBidForAuction, alice.balance - aliceBeforeBalance, "Received bounty for snuff is incorrect");

        // Check if bidder received token.
        assertEq(mockAuctionableToken.balanceOf(bids[winnerBidIds[0]].bidder), 1, "Bidder did not receive token");

        // Check that alice did not receive any tokens.
        assertEq(mockAuctionableToken.balanceOf(alice), 0, "Alice received tokens, when she shouldn't have");

        // Fail to claim tokens that are already claimed.
        vm.expectRevert(abi.encodeWithSignature("BidAlreadyClaimed()"));
        kandilli.claimWinningBid(auctionId, winnerBidIds[0], hash, winnerBidIds, 0);
    }

    function testChallengeWinnersProposal() public {
        kandilli.init();

        uint256 auctionId = 1;
        uint256 startTime = kandilli.getAuctionStartTime(auctionId);
        uint256 depositAmount = kandilli.getAuctionRequiredWinnersProposalDeposit(auctionId);

        // Fail when posting winners before candle snuffed
        {
            uint32[] memory dummyWinnerIds = new uint32[](3);
            bytes32 dummyHash = keccak256(abi.encodePacked("x"));

            dummyWinnerIds[0] = 3;
            dummyWinnerIds[1] = 3;
            dummyWinnerIds[2] = 3;
            vm.expectRevert(abi.encodeWithSignature("CannotPostWinnersBeforeVRFSetOrWhenWinnersAlreadyPosted()"));
            kandilli.postWinners{value: depositAmount}(auctionId, dummyWinnerIds, dummyHash);
        }

        _sendBids(auctionId, 100);
        _snuffCandle(auctionId, randomE, startTime);

        // Try to challenge when winners not yet posted
        {
            uint32[] memory dummyWinnerIds = new uint32[](3);
            dummyWinnerIds[0] = 3;
            dummyWinnerIds[1] = 3;
            dummyWinnerIds[2] = 3;
            vm.expectRevert(abi.encodeWithSignature("CannotChallengeWinnersProposalBeforePosted()"));
            kandilli.challengePostedWinners(auctionId, dummyWinnerIds, keccak256(abi.encodePacked("x")), 0, 0);
        }

        IKandilli.KandilBid[] memory bids = kandilli.getAuctionBids(auctionId);

        uint256 snuffTime = kandilli.getAuctionCandleSnuffedTime(auctionId);
        uint256 bidCount = 0;
        // Count bids sent before snuff time, in test env, time starts from 0 so no need to convert.
        for (uint256 i = 0; i < bids.length; i++) {
            if (startTime + bids[i].timePassedFromStart < snuffTime) {
                bidCount++;
            }
        }
        console.log("TotalBid", bids.length);
        console.log("BidCountBeforeSnuff", bidCount);
        //Bid with index to sort with for same amount and same timestamp bids.
        KandilBidWithIndex[] memory nBids = new KandilBidWithIndex[](bidCount);
        for (uint256 i = 0; i < bidCount; i++) {
            nBids[i] = KandilBidWithIndex(bids[i].bidder, bids[i].timePassedFromStart, bids[i].bidAmount, bids[i].isClaimed, i);
        }
        _quickSort(nBids, 0, nBids.length - 1);

        uint256 numWinners = kandilli.getAuctionWinnerCount(auctionId);
        uint256 vrfResult = kandilli.getAuctionVRF(auctionId);

        uint32[] memory winnerBidIds = new uint32[](numWinners);
        for (uint256 i = 0; i < numWinners; i++) {
            winnerBidIds[i] = uint32(nBids[i].index);
        }

        // Fail when posting winners with wrong hash
        vm.expectRevert(abi.encodeWithSignature("IncorrectHashForWinnerBids()"));
        kandilli.postWinners{value: depositAmount}(auctionId, winnerBidIds, keccak256(abi.encodePacked("x")));

        bytes32 hash = keccak256(abi.encodePacked(winnerBidIds, vrfResult));

        // Fail when posting winners with wrong deposit amount
        vm.expectRevert(abi.encodeWithSignature("DepositAmountForWinnersProposalNotMet()"));
        kandilli.postWinners{value: 1 wei}(auctionId, winnerBidIds, hash);

        kandilli.postWinners{value: depositAmount}(auctionId, winnerBidIds, hash);

        // Fail when posting winners a second time
        vm.expectRevert(abi.encodeWithSignature("CannotPostWinnersBeforeVRFSetOrWhenWinnersAlreadyPosted()"));
        kandilli.postWinners{value: depositAmount}(auctionId, winnerBidIds, hash);

        // Fail try to challenge after challenge period
        vm.warp(startTime + auctionTotalDuration + fraudChallengePeriod + 2);
    }

    // TODO: This needs to sort first by bidAmount then by bidId
    // and if the time's are also same by index (which is the order of bid)
    // currently only sorting by bidAmount
    function _quickSort(
        KandilBidWithIndex[] memory arr,
        uint256 left,
        uint256 right
    ) private pure {
        uint256 i = left;
        uint256 j = right;
        if (i == j) return;
        uint256 pivot = arr[left + (right - left) / 2].bidAmount;
        while (i <= j) {
            while (arr[i].bidAmount < pivot) i++;
            while (pivot < arr[j].bidAmount) j--;
            if (i <= j) {
                (arr[i], arr[j]) = (arr[j], arr[i]);
                i++;
                j--;
            }
        }
        if (left < j) _quickSort(arr, left, j);
        if (i < right) _quickSort(arr, i, right);
    }

    function _sendBids(uint256 auctionId, uint256 bidCountToSend) private {
        for (uint256 i = 0; i < bidCountToSend; i++) {
            uint256 rand = uint256(uint160(address(users[i])));
            vm.prank(users[i]);
            kandilli.addBidToAuction{value: ((rand % 1000000) + 200000) * 100 gwei}(auctionId);
        }
    }

    function _snuffCandle(
        uint256 auctionId,
        uint256 vrf,
        uint256 startTime
    ) private {
        vm.warp(startTime + auctionTotalDuration + 1);
        vm.startPrank(users[0]);
        linkToken.approve(address(kandilli), vrfFee);
        bytes32 requestId = kandilli.retroSnuffCandle(auctionId);
        vrfCoordinatorMock.callBackWithRandomness(requestId, vrf, address(kandilli));
        vm.stopPrank();
    }
}

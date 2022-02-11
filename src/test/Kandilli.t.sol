// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.11;

import {DSTest} from "ds-test/test.sol";
import {Utilities} from "./utils/Utilities.sol";
import {console} from "./utils/Console.sol";
import "forge-std/Vm.sol";
import {Kandilli} from "../Kandilli.sol";
import {MockAuctionableToken} from "./mocks/MockAuctionableToken.sol";
import {WETH} from "./mocks/WETH.sol";
import {LinkTokenMock} from "./mocks/LinkTokenMock.sol";
import {VRFCoordinatorMock} from "chainlink/contracts/src/v0.8/mocks/VRFCoordinatorMock.sol";
import {IKandilli} from "../interfaces/IKandilli.sol";
import {Helpers} from "../lib/Helpers.sol";
import "../../lib/openzeppelin-contracts/contracts/mocks/SafeERC20Helper.sol";

struct ProposeWinnersResult {
    bytes32 hash;
    uint32[] winnerBidIds;
    IKandilli.KandilBidWithIndex[] nBids;
    IKandilli.KandilBid[] bids;
    uint256 vrfResult;
    uint256 numWinners;
    uint256 snuffTime;
}

contract KandilliTest is DSTest {
    event AuctionStarted(uint256 auctionId, uint256 startTime);
    event AuctionBid(address indexed sender, uint256 auctionId, uint256 bidId, uint256 value);
    event AuctionBidIncrease(address indexed sender, uint256 auctionId, uint256 bidId, uint256 value);
    event ChallengeSucceded(address indexed sender, uint256 auctionId, uint256 reason);
    event AuctionWinnersProposed(address indexed sender, uint256 auctionId, bytes32 hash);
    event LostBidWithdrawn(uint256 auctionId, uint256 bidId, address sender);
    event VRFRequested(address indexed sender, uint256 auctionId, bytes32 requestId);
    event WinningBidClaimed(address indexed sender, uint256 auctionId, uint256 bidId, address claimedto);

    event Approval(address indexed owner, address indexed spender, uint256 value);

    Vm internal immutable vm = Vm(HEVM_ADDRESS);

    Utilities internal utils;
    Kandilli internal kandilli;
    MockAuctionableToken internal mockAuctionableToken;
    LinkTokenMock internal linkToken;
    VRFCoordinatorMock internal vrfCoordinatorMock;
    WETH internal weth;
    address payable[] internal users;

    uint64 internal winnersProposalDeposit = (1 ether) / (1 gwei); // 1 ether
    uint32 internal desiredNumWinners = 32; // 32 users
    uint32 internal auctionTotalDuration = 259200; // 3 days
    uint32 internal fraudChallengePeriod = 10800; // 3 hours
    uint32 internal retroSnuffGas = 400_000; // 200k gas
    uint32 internal postWinnerGasCost = 500_000; // 200k gas
    uint64 internal initialTargetBaseFee = 100 gwei; // 100 gwei
    uint64 internal vrfFee = 100_000;
    bytes32 internal keyHash = 0x6c3699283bda56ad74f6b855546325b68d482e983852a7a82979cc4807b641f4;
    // If you change this make sure there's less winners than bids that are before snuff time.
    // Otherwise some tests will fail.
    uint256 internal randomE = 18392480285055155400540772292264222449548204563388120189582018752977384988357;
    uint8 internal maxBountyMultiplier = 10;
    uint8 internal snuffPercentage = 30;

    bool userPaysLink = false;

    // This is to get a random number via FFI. Can comment out and enable ffi via (test --ffi or via toml)
    // Requires nodejs installed
    bool randomViaFFI = false;

    function setUp() public {
        utils = new Utilities();
        if (randomViaFFI) {
            randomE = utils.getRandomNumber();
        }
        users = utils.createUsers(100);
        mockAuctionableToken = new MockAuctionableToken();
        // Give users[0] link tokens
        linkToken = new LinkTokenMock("LinkToken", "LINK", users[0], 5e18);
        vrfCoordinatorMock = new VRFCoordinatorMock(address(linkToken));
        weth = new WETH();
        IKandilli.KandilAuctionSettings memory settings = IKandilli.KandilAuctionSettings(
            winnersProposalDeposit,
            fraudChallengePeriod,
            retroSnuffGas,
            postWinnerGasCost,
            auctionTotalDuration,
            desiredNumWinners,
            maxBountyMultiplier,
            snuffPercentage,
            false
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
            vrfFee,
            keyHash
        );
        if (!userPaysLink) {
            linkToken.mint(address(kandilli), 5e18);
        }
    }

    function testBids() public {
        kandilli.init();
        uint256 auctionId = 1;
        uint256 startTime = kandilli.getAuctionStartTime(auctionId);
        address payable alice = users[0];
        address payable bob = users[1];
        vm.prank(alice);
        vm.expectEmit(true, true, true, true);
        emit AuctionBid(alice, auctionId, 0, 1 ether);
        kandilli.addBidToAuction{value: 1 ether}(auctionId);
        vm.prank(bob);
        vm.expectEmit(true, true, true, true);
        emit AuctionBid(bob, auctionId, 1, 1 ether);
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
    }

    function testIncreaseBid() public {
        kandilli.init();
        uint256 auctionId = 1;
        address payable alice = users[0];
        address payable bob = users[1];
        uint256 startTime = kandilli.getAuctionStartTime(auctionId);
        // Send dummy bids first to clutter.
        _sendBids(auctionId, 20, startTime, randomE);

        vm.startPrank(alice);
        uint256 aliceOldBalance = alice.balance;
        uint256 bidId = kandilli.addBidToAuction{value: 1 ether}(auctionId);
        vm.expectEmit(true, true, true, true);
        emit AuctionBidIncrease(alice, auctionId, bidId, 1 ether);
        kandilli.increaseAmountOfBid{value: 1 ether}(auctionId, bidId);
        uint256 aliceNewBalance = alice.balance;

        assertEq(aliceOldBalance - aliceNewBalance, 2 ether);

        IKandilli.KandilBid[] memory bids = kandilli.getAuctionBids(auctionId, 0, 1000);
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
        _sendBids(auctionId, 20, startTime, randomE);

        vm.expectRevert(abi.encodeWithSignature("CannotSnuffCandleBeforeDefiniteEndTime()"));
        kandilli.retroSnuffCandle(1);

        vm.expectRevert(abi.encodeWithSignature("CannotSnuffCandleForNotRunningAuction()"));
        kandilli.retroSnuffCandle(99);

        uint256 aliceOldBalance = alice.balance;
        vm.warp(startTime + auctionTotalDuration + timePassed);
        uint256 bounty = kandilli.getAuctionRetroSnuffBounty(auctionId);

        assertLe(bounty, uint256(maxBountyMultiplier) * uint256(retroSnuffGas) * (100 gwei));
        assertGe(bounty, uint256(retroSnuffGas) * (100 gwei));

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
            vm.expectEmit(true, false, false, false);
            emit VRFRequested(alice, auctionId, bytes32(0));
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

    function testPostWinners(uint256 randomE) public {
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
            vm.expectRevert(abi.encodeWithSignature("CannotProposeWinnersBeforeVRFSetOrWhenWinnersAlreadyPosted()"));
            kandilli.proposeWinners{value: depositAmount}(auctionId, dummyWinnerIds, dummyHash);
        }

        _sendBids(auctionId, 100, startTime, randomE);
        _snuffCandle(auctionId, randomE, startTime);

        IKandilli.KandilBid[] memory bids = kandilli.getAuctionBids(auctionId, 0, 1000);

        uint256 snuffTime = kandilli.getAuctionCandleSnuffedTime(auctionId);
        uint256 bidCount = 0;
        // Count bids sent before snuff time.
        for (uint256 i = 0; i < bids.length; i++) {
            if (startTime + bids[i].timePassedFromStart < snuffTime) {
                bidCount++;
            }
        }
        //Bid with index to sort with for same amount.
        IKandilli.KandilBidWithIndex[] memory nBids = new IKandilli.KandilBidWithIndex[](bidCount);
        {
            uint256 ni = 0;
            for (uint32 i = 0; i < bids.length; i++) {
                if (startTime + bids[i].timePassedFromStart < snuffTime) {
                    nBids[ni++] = IKandilli.KandilBidWithIndex(
                        bids[i].bidder,
                        bids[i].timePassedFromStart,
                        bids[i].bidAmount,
                        bids[i].isProcessed,
                        i
                    );
                }
            }
        }

        nBids = Helpers.sortBids(nBids);
        uint32[] memory winnerBidIds;
        uint256 vrfResult = kandilli.getAuctionVRF(auctionId);
        {
            uint256 numWinners = kandilli.getAuctionWinnerCount(auctionId);
            if (numWinners > nBids.length) {
                numWinners = nBids.length;
            }
            winnerBidIds = new uint32[](numWinners);
            for (uint256 i = 0; i < numWinners; i++) {
                winnerBidIds[i] = uint32(nBids[i].index);
            }
        }

        // Fail when posting winners with wrong hash
        vm.expectRevert(abi.encodeWithSignature("IncorrectHashForWinnerBids()"));
        kandilli.proposeWinners{value: depositAmount}(auctionId, winnerBidIds, keccak256(abi.encodePacked("x")));

        bytes32 hash = keccak256(abi.encodePacked(winnerBidIds, vrfResult));

        // Fail when posting winners with wrong deposit amount
        vm.expectRevert(abi.encodeWithSignature("DepositAmountForWinnersProposalNotMet()"));
        kandilli.proposeWinners{value: 1 wei}(auctionId, winnerBidIds, hash);

        // Succeed to post winners and check balance
        {
            address payable alice = users[0];
            uint256 aliceBalanceBefore = alice.balance;
            vm.prank(alice);
            vm.expectEmit(true, false, false, true);
            emit AuctionWinnersProposed(alice, auctionId, hash);
            kandilli.proposeWinners{value: depositAmount}(auctionId, winnerBidIds, hash);
            uint256 aliceBalanceAfter = alice.balance;
            assertEq(aliceBalanceBefore - aliceBalanceAfter, depositAmount);
        }

        // Fail when posting winners a second time
        {
            vm.expectRevert(abi.encodeWithSignature("CannotProposeWinnersBeforeVRFSetOrWhenWinnersAlreadyPosted()"));
            kandilli.proposeWinners{value: depositAmount}(auctionId, winnerBidIds, hash);
        }
    }

    function testClaimToken(uint256 randomE) public {
        kandilli.init();

        uint256 auctionId = 1;
        uint256 startTime = kandilli.getAuctionStartTime(auctionId);
        uint32[] memory dummyWinnerIds = new uint32[](3);

        _sendBids(auctionId, 100, startTime, randomE);
        _snuffCandle(auctionId, randomE, startTime);

        vm.expectRevert(abi.encodeWithSignature("CannotClaimAuctionItemBeforeWinnersPosted()"));
        kandilli.claimWinningBid(auctionId, dummyWinnerIds[0], bytes32(0), dummyWinnerIds, 0);

        ProposeWinnersResult memory pwr = _proposeWinners(auctionId, startTime, true);

        vm.expectRevert(abi.encodeWithSignature("CannotClaimAuctionItemBeforeChallengePeriodEnds()"));
        kandilli.claimWinningBid(auctionId, pwr.winnerBidIds[0], pwr.hash, pwr.winnerBidIds, 0);

        vm.warp(startTime + auctionTotalDuration + fraudChallengePeriod + 2);

        vm.expectRevert(abi.encodeWithSignature("WinnerProposalBidIdDoesntMatch()"));
        kandilli.claimWinningBid(auctionId, pwr.winnerBidIds[0], pwr.hash, pwr.winnerBidIds, 5);

        bytes32 dummyHash = keccak256(abi.encodePacked(dummyWinnerIds, pwr.vrfResult));
        dummyWinnerIds[0] = 0;
        dummyWinnerIds[1] = 4;
        dummyWinnerIds[2] = 1;
        vm.expectRevert(abi.encodeWithSignature("WinnerProposalDataDoesntHaveCorrectHash()"));
        kandilli.claimWinningBid(auctionId, dummyWinnerIds[0], dummyHash, dummyWinnerIds, 0);

        dummyHash = keccak256(abi.encodePacked(dummyWinnerIds, pwr.vrfResult));
        vm.expectRevert(abi.encodeWithSignature("WinnerProposalHashDoesntMatchPostedHash()"));
        kandilli.claimWinningBid(auctionId, dummyWinnerIds[0], dummyHash, dummyWinnerIds, 0);

        address payable alice = payable(address(uint160(uint256(keccak256(abi.encodePacked("someOtherUser"))))));
        uint256 aliceBeforeBalance = alice.balance;
        vm.prank(alice);
        vm.expectEmit(true, false, false, true);
        emit WinningBidClaimed(alice, 56, pwr.winnerBidIds[0], pwr.bids[pwr.winnerBidIds[0]].bidder);
        kandilli.claimWinningBid(auctionId, pwr.winnerBidIds[0], pwr.hash, pwr.winnerBidIds, 0);
        uint256 claimBounty = kandilli.getClaimWinningBidBounty(auctionId);

        // Check if alice received right bounty.
        assertEq(claimBounty, alice.balance - aliceBeforeBalance, "Received bounty for snuff is incorrect");

        // Check if bidder received token.
        assertEq(mockAuctionableToken.balanceOf(pwr.bids[pwr.winnerBidIds[0]].bidder), 1, "Bidder did not receive token");

        // Check that alice did not receive any tokens.
        assertEq(mockAuctionableToken.balanceOf(alice), 0, "Alice received tokens, when she shouldn't have");

        // Fail to claim tokens that are already claimed.
        vm.expectRevert(abi.encodeWithSignature("BidAlreadyClaimed()"));
        kandilli.claimWinningBid(auctionId, pwr.winnerBidIds[0], pwr.hash, pwr.winnerBidIds, 0);
    }

    function testWithdrawBid(uint256 randomE) public {
        kandilli.init();

        uint256 auctionId = 1;
        uint256 startTime = kandilli.getAuctionStartTime(auctionId);

        _sendBids(auctionId, 100, startTime, randomE);
        _snuffCandle(auctionId, randomE, startTime);

        ProposeWinnersResult memory pwr = _proposeWinners(auctionId, startTime, true);

        vm.warp(startTime + auctionTotalDuration + fraudChallengePeriod + 2);

        uint32[] memory dummyWinnerIds = new uint32[](3);
        bytes32 dummyHash = keccak256(abi.encodePacked(dummyWinnerIds, pwr.vrfResult));
        dummyWinnerIds[0] = 0;
        dummyWinnerIds[1] = 4;
        dummyWinnerIds[2] = 1;
        vm.expectRevert(abi.encodeWithSignature("WinnerProposalDataDoesntHaveCorrectHash()"));
        kandilli.withdrawLostBid(auctionId, dummyWinnerIds[0], dummyHash, dummyWinnerIds);

        dummyHash = keccak256(abi.encodePacked(dummyWinnerIds, pwr.vrfResult));
        vm.expectRevert(abi.encodeWithSignature("WinnerProposalHashDoesntMatchPostedHash()"));
        kandilli.withdrawLostBid(auctionId, dummyWinnerIds[0], dummyHash, dummyWinnerIds);

        vm.expectRevert(abi.encodeWithSignature("CannotWithdrawLostBidIfIncludedInWinnersProposal()"));
        kandilli.withdrawLostBid(auctionId, pwr.winnerBidIds[0], pwr.hash, pwr.winnerBidIds);

        vm.expectRevert(abi.encodeWithSignature("CannotWithdrawBidIfNotSender()"));
        kandilli.withdrawLostBid(auctionId, pwr.nBids[pwr.numWinners + 1].index, pwr.hash, pwr.winnerBidIds);

        uint256 beforeBalance = pwr.nBids[pwr.numWinners + 1].bidder.balance;

        emit LostBidWithdrawn(3, pwr.nBids[pwr.numWinners].index, pwr.nBids[pwr.numWinners + 1].bidder);
        vm.prank(pwr.nBids[pwr.numWinners + 1].bidder);
        kandilli.withdrawLostBid(auctionId, pwr.nBids[pwr.numWinners + 1].index, pwr.hash, pwr.winnerBidIds);
        uint256 afterBalance = pwr.nBids[pwr.numWinners + 1].bidder.balance;

        assertEq(
            afterBalance - beforeBalance,
            uint256(pwr.nBids[pwr.numWinners + 1].bidAmount) * (1 gwei),
            "Didn't withdraw correct amount"
        );

        vm.expectRevert(abi.encodeWithSignature("CannotWithdrawAlreadyWithdrawnBid()"));
        kandilli.withdrawLostBid(auctionId, pwr.nBids[pwr.numWinners + 1].index, pwr.hash, pwr.winnerBidIds);
    }

    function testChallengeWinnersProposals(uint256 randomE) public {
        kandilli.init();

        uint256 auctionId = 1;
        uint256 startTime = kandilli.getAuctionStartTime(auctionId);
        uint256 depositAmount = kandilli.getAuctionRequiredWinnersProposalDeposit(auctionId);

        _sendBids(auctionId, 100, startTime, randomE);
        _snuffCandle(auctionId, randomE, startTime);
        ProposeWinnersResult memory pwr = _proposeWinners(auctionId, startTime, false);
        // Send more winner bids than total bid count
        {
            uint32[] memory dummyWinnerIds = new uint32[](pwr.bids.length + 1);
            bytes32 dummyHash = keccak256(abi.encodePacked(dummyWinnerIds, pwr.vrfResult));
            kandilli.proposeWinners{value: depositAmount}(auctionId, dummyWinnerIds, dummyHash);
            address challenger = payable(address(uint160(uint256(keccak256(abi.encodePacked("challenger"))))));

            vm.expectEmit(true, false, false, true);
            emit ChallengeSucceded(challenger, auctionId, 1);
            vm.prank(challenger);
            uint256 chalBalBefore = challenger.balance;
            kandilli.challengeProposedWinners(auctionId, dummyWinnerIds, dummyHash, 1);
            uint256 chalBalAfter = challenger.balance;
            assertEq(chalBalAfter, chalBalBefore + depositAmount, "Challenger didn't receive enough reward");
        }

        // Send duplicate winner bids
        {
            uint32[] memory dummyWinnerIds = new uint32[](3);
            dummyWinnerIds[0] = 5;
            dummyWinnerIds[1] = 3;
            dummyWinnerIds[2] = 5;
            bytes32 dummyHash = keccak256(abi.encodePacked(dummyWinnerIds, pwr.vrfResult));
            kandilli.proposeWinners{value: depositAmount}(auctionId, dummyWinnerIds, dummyHash);
            address challenger = payable(address(uint160(uint256(keccak256(abi.encodePacked("challenger"))))));

            vm.expectEmit(true, false, false, true);
            emit ChallengeSucceded(challenger, auctionId, 2);
            vm.prank(challenger);
            uint256 chalBalBefore = challenger.balance;
            kandilli.challengeProposedWinners(auctionId, dummyWinnerIds, dummyHash, 2);
            uint256 chalBalAfter = challenger.balance;
            assertEq(chalBalAfter, chalBalBefore + depositAmount, "Challenger didn't receive enough reward");
        }

        // Send bigger winner index than total bid count.
        {
            uint32[] memory dummyWinnerIds = new uint32[](3);
            uint256 z = 0;
            for (uint256 i = 0; i < pwr.bids.length; i++) {
                if (startTime + pwr.bids[i].timePassedFromStart < pwr.snuffTime) {
                    dummyWinnerIds[z] = uint32(i);
                    z++;
                    if (z == 3) {
                        break;
                    }
                }
            }
            uint32 toIncl = dummyWinnerIds[2];
            dummyWinnerIds[2] = uint32(pwr.bids.length);
            bytes32 dummyHash = keccak256(abi.encodePacked(dummyWinnerIds, pwr.vrfResult));
            kandilli.proposeWinners{value: depositAmount}(auctionId, dummyWinnerIds, dummyHash);
            address challenger = payable(address(uint160(uint256(keccak256(abi.encodePacked("challenger"))))));

            vm.expectEmit(true, false, false, true);
            emit ChallengeSucceded(challenger, auctionId, 3);
            vm.prank(challenger);
            uint256 chalBalBefore = challenger.balance;
            kandilli.challengeProposedWinners(auctionId, dummyWinnerIds, dummyHash, toIncl);
            uint256 chalBalAfter = challenger.balance;
            assertEq(chalBalAfter, chalBalBefore + depositAmount, "Challenger didn't receive enough reward");
        }

        // Send bid which is after snuff time
        {
            uint32[] memory dummyWinnerIds = new uint32[](3);
            uint256 z = 0;
            for (uint256 i = 0; i < pwr.bids.length; i++) {
                if (startTime + pwr.bids[i].timePassedFromStart >= pwr.snuffTime) {
                    dummyWinnerIds[0] = uint32(i);
                    break;
                } else if (z < 2) {
                    dummyWinnerIds[z + 1] = uint32(i);
                    z++;
                }
            }
            bytes32 dummyHash = keccak256(abi.encodePacked(dummyWinnerIds, pwr.vrfResult));
            kandilli.proposeWinners{value: depositAmount}(auctionId, dummyWinnerIds, dummyHash);
            address challenger = payable(address(uint160(uint256(keccak256(abi.encodePacked("challenger"))))));

            vm.expectEmit(true, false, false, true);
            emit ChallengeSucceded(challenger, auctionId, 4);
            vm.prank(challenger);
            uint256 chalBalBefore = challenger.balance;
            kandilli.challengeProposedWinners(auctionId, dummyWinnerIds, dummyHash, 0);
            uint256 chalBalAfter = challenger.balance;
            assertEq(chalBalAfter, chalBalBefore + depositAmount, "Challenger didn't receive enough reward");
        }

        // Send bid which is after snuff time
        {
            uint32[] memory dummyWinnerIds = new uint32[](3);
            uint256 z = 0;
            for (uint256 i = 0; i < pwr.bids.length; i++) {
                if (startTime + pwr.bids[i].timePassedFromStart >= pwr.snuffTime) {
                    dummyWinnerIds[0] = uint32(i);
                    break;
                } else if (z < 2) {
                    dummyWinnerIds[z + 1] = uint32(i);
                    z++;
                }
            }
            bytes32 dummyHash = keccak256(abi.encodePacked(dummyWinnerIds, pwr.vrfResult));
            kandilli.proposeWinners{value: depositAmount}(auctionId, dummyWinnerIds, dummyHash);
            address challenger = payable(address(uint160(uint256(keccak256(abi.encodePacked("challenger"))))));

            vm.expectEmit(true, false, false, true);
            emit ChallengeSucceded(challenger, auctionId, 4);
            vm.prank(challenger);
            uint256 chalBalBefore = challenger.balance;
            kandilli.challengeProposedWinners(auctionId, dummyWinnerIds, dummyHash, 0);
            uint256 chalBalAfter = challenger.balance;
            assertEq(chalBalAfter, chalBalBefore + depositAmount, "Challenger didn't receive enough reward");
        }

        // Send bad list #1
        {
            uint32[] memory dummyWinnerIds = new uint32[](pwr.numWinners);
            for (uint256 i = 0; i < pwr.numWinners - 1; i++) {
                dummyWinnerIds[i] = uint32(pwr.nBids[i].index);
            }
            dummyWinnerIds[pwr.numWinners - 1] = uint32(pwr.nBids[pwr.numWinners].index);
            bytes32 dummyHash = keccak256(abi.encodePacked(dummyWinnerIds, pwr.vrfResult));
            kandilli.proposeWinners{value: depositAmount}(auctionId, dummyWinnerIds, dummyHash);
            address challenger = payable(address(uint160(uint256(keccak256(abi.encodePacked("challenger"))))));

            vm.expectEmit(true, false, false, true);
            emit ChallengeSucceded(challenger, auctionId, 6);
            vm.prank(challenger);
            uint256 chalBalBefore = challenger.balance;
            kandilli.challengeProposedWinners(auctionId, dummyWinnerIds, dummyHash, uint32(pwr.nBids[pwr.numWinners - 1].index));
            uint256 chalBalAfter = challenger.balance;
            assertEq(chalBalAfter, chalBalBefore + depositAmount, "Challenger didn't receive enough reward");
        }

        // Try to repropose winners after successful fraud proof.
        _proposeWinners(auctionId, startTime, true);
    }

    function testChallengeWinnersProposalFailures(uint256 randomE) public {
        kandilli.init();

        uint256 auctionId = 1;
        uint256 startTime = kandilli.getAuctionStartTime(auctionId);
        uint256 depositAmount = kandilli.getAuctionRequiredWinnersProposalDeposit(auctionId);

        _sendBids(auctionId, 100, startTime, randomE);
        _snuffCandle(auctionId, randomE, startTime);

        // Try to challenge when winners not yet posted
        {
            uint32[] memory dummyWinnerIds = new uint32[](3);
            dummyWinnerIds[0] = 3;
            dummyWinnerIds[1] = 3;
            dummyWinnerIds[2] = 3;
            vm.expectRevert(abi.encodeWithSignature("CannotChallengeWinnersProposalBeforePosted()"));
            kandilli.challengeProposedWinners(auctionId, dummyWinnerIds, keccak256(abi.encodePacked("x")), 0);
        }

        ProposeWinnersResult memory pwr = _proposeWinners(auctionId, startTime, true);

        {
            bytes32 whash = keccak256(abi.encodePacked(pwr.winnerBidIds, "x"));
            vm.expectRevert(abi.encodeWithSignature("WinnerProposalDataDoesntHaveCorrectHash()"));
            kandilli.challengeProposedWinners(auctionId, pwr.winnerBidIds, whash, 0);
        }

        {
            uint32[] memory dummyWinnerIds = new uint32[](3);
            dummyWinnerIds[0] = 3;
            dummyWinnerIds[1] = 3;
            dummyWinnerIds[2] = 3;
            bytes32 dummyHash = keccak256(abi.encodePacked(dummyWinnerIds, pwr.vrfResult));
            vm.expectRevert(abi.encodeWithSignature("WinnerProposalHashDoesntMatchPostedHash()"));
            kandilli.challengeProposedWinners(auctionId, dummyWinnerIds, dummyHash, 0);
        }
        vm.expectRevert(abi.encodeWithSignature("CannotChallengeSelfProposal()"));
        kandilli.challengeProposedWinners(auctionId, pwr.winnerBidIds, pwr.hash, 0);

        vm.startPrank(payable(address(uint160(uint256(keccak256(abi.encodePacked("challenger")))))));
        vm.expectRevert(abi.encodeWithSignature("ChallengeFailedBidIdToIncludeAlreadyInWinnerList()"));
        kandilli.challengeProposedWinners(auctionId, pwr.winnerBidIds, pwr.hash, pwr.winnerBidIds[0]);

        vm.expectRevert(abi.encodeWithSignature("ChallengeFailedBidIdToIncludeIsNotInBidList()"));
        kandilli.challengeProposedWinners(auctionId, pwr.winnerBidIds, pwr.hash, uint32(pwr.bids.length));

        if (pwr.nBids.length > pwr.numWinners) {
            vm.expectRevert(abi.encodeWithSignature("ChallengeFailedWinnerProposalIsCorrect()"));
            kandilli.challengeProposedWinners(auctionId, pwr.winnerBidIds, pwr.hash, pwr.nBids[pwr.numWinners].index);
        }
        // Fail to challenge after challenge period
        vm.warp(startTime + auctionTotalDuration + fraudChallengePeriod + 2);
        vm.expectRevert(abi.encodeWithSignature("CannotChallengeWinnersProposalAfterChallengePeriodIsOver()"));
        kandilli.challengeProposedWinners(auctionId, pwr.winnerBidIds, pwr.hash, 0);
    }

    function testSort() public {
        IKandilli.KandilBidWithIndex[] memory nBids = new IKandilli.KandilBidWithIndex[](15);
        nBids[0] = IKandilli.KandilBidWithIndex(users[0], 0, 100, false, 0);
        nBids[1] = IKandilli.KandilBidWithIndex(users[1], 0, 150, false, 1);
        nBids[2] = IKandilli.KandilBidWithIndex(users[2], 0, 150, false, 2);
        nBids[3] = IKandilli.KandilBidWithIndex(users[3], 0, 150, false, 3);
        nBids[4] = IKandilli.KandilBidWithIndex(users[4], 0, 150, false, 4);
        nBids[5] = IKandilli.KandilBidWithIndex(users[5], 0, 500, false, 9);
        nBids[6] = IKandilli.KandilBidWithIndex(users[6], 0, 500, false, 6);
        nBids[7] = IKandilli.KandilBidWithIndex(users[7], 0, 1500, false, 7);
        nBids[8] = IKandilli.KandilBidWithIndex(users[8], 0, 100, false, 8);
        nBids[9] = IKandilli.KandilBidWithIndex(users[9], 0, 500, false, 5);
        nBids[10] = IKandilli.KandilBidWithIndex(users[10], 0, 120, false, 10);
        nBids[11] = IKandilli.KandilBidWithIndex(users[11], 0, 100, false, 13);
        nBids[12] = IKandilli.KandilBidWithIndex(users[12], 0, 100, false, 11);
        nBids[13] = IKandilli.KandilBidWithIndex(users[12], 0, 100, false, 12);
        nBids[14] = IKandilli.KandilBidWithIndex(users[12], 0, 1501, false, 14);

        nBids = Helpers.sortBids(nBids);

        IKandilli.KandilBidWithIndex[] memory expectedBids = new IKandilli.KandilBidWithIndex[](15);
        expectedBids[0] = IKandilli.KandilBidWithIndex(users[12], 0, 1501, false, 14);
        expectedBids[1] = IKandilli.KandilBidWithIndex(users[7], 0, 1500, false, 7);
        expectedBids[2] = IKandilli.KandilBidWithIndex(users[9], 0, 500, false, 5);
        expectedBids[3] = IKandilli.KandilBidWithIndex(users[6], 0, 500, false, 6);
        expectedBids[4] = IKandilli.KandilBidWithIndex(users[5], 0, 500, false, 9);
        expectedBids[5] = IKandilli.KandilBidWithIndex(users[1], 0, 150, false, 1);
        expectedBids[6] = IKandilli.KandilBidWithIndex(users[2], 0, 150, false, 2);
        expectedBids[7] = IKandilli.KandilBidWithIndex(users[3], 0, 150, false, 3);
        expectedBids[8] = IKandilli.KandilBidWithIndex(users[4], 0, 150, false, 4);
        expectedBids[9] = IKandilli.KandilBidWithIndex(users[10], 0, 120, false, 10);
        expectedBids[10] = IKandilli.KandilBidWithIndex(users[0], 0, 100, false, 0);
        expectedBids[11] = IKandilli.KandilBidWithIndex(users[8], 0, 100, false, 8);
        expectedBids[12] = IKandilli.KandilBidWithIndex(users[12], 0, 100, false, 11);
        expectedBids[13] = IKandilli.KandilBidWithIndex(users[12], 0, 100, false, 12);
        expectedBids[14] = IKandilli.KandilBidWithIndex(users[11], 0, 100, false, 13);

        assertEq(keccak256(abi.encode(nBids)), keccak256(abi.encode(expectedBids)));
    }

    function testBidPaging() public {
        kandilli.init();

        uint256 auctionId = 1;
        uint256 startTime = kandilli.getAuctionStartTime(auctionId);
        uint256 depositAmount = kandilli.getAuctionRequiredWinnersProposalDeposit(auctionId);

        _sendBids(auctionId, 100, startTime, randomE);

        IKandilli.KandilBid[] memory bids1 = kandilli.getAuctionBids(auctionId, 0, 50);
        IKandilli.KandilBid[] memory bids2 = kandilli.getAuctionBids(auctionId, 1, 50);
        IKandilli.KandilBid[] memory bids = kandilli.getAuctionBids(auctionId, 0, 0);

        for (uint256 i = 0; i < 100; i++) {
            if (i < 50) {
                assertEq(bids[i].bidder, bids1[i].bidder);
                assertEq(bids[i].timePassedFromStart, bids1[i].timePassedFromStart);
                assertEq(bids[i].bidAmount, bids1[i].bidAmount);
            } else {
                assertEq(bids[i].bidder, bids2[i - 50].bidder);
                assertEq(bids[i].timePassedFromStart, bids2[i - 50].timePassedFromStart);
                assertEq(bids[i].bidAmount, bids2[i - 50].bidAmount);
            }
        }
    }

    function _sendBids(
        uint256 auctionId,
        uint256 bidCountToSend,
        uint256 startTime,
        uint256 randE
    ) private {
        for (uint256 i = 0; i < bidCountToSend; i++) {
            uint256 rand = uint256(keccak256(abi.encodePacked(randE, uint256(uint160(address(users[i]))))));
            vm.warp(startTime + uint256(rand % auctionTotalDuration));
            vm.prank(users[i]);
            vm.expectEmit(true, false, false, true);
            emit AuctionBid(users[i], auctionId, i, ((rand % 1000000) + 200000) * 100 gwei);
            kandilli.addBidToAuction{value: ((rand % 1000000) + 200000) * 100 gwei}(auctionId);
        }
    }

    function _snuffCandle(
        uint256 auctionId,
        uint256 vrf,
        uint256 startTime
    ) private {
        vm.warp(startTime + auctionTotalDuration + 1);
        address snuffer = payable(address(uint160(uint256(keccak256(abi.encodePacked("snuffer"))))));
        vm.startPrank(snuffer);

        vm.expectEmit(true, true, false, true);
        emit Approval(snuffer, address(kandilli), vrfFee);
        linkToken.approve(address(kandilli), vrfFee);

        vm.expectEmit(true, false, false, true);
        emit AuctionStarted(auctionId + 1, startTime + auctionTotalDuration + 1);
        vm.expectEmit(true, false, false, true);
        emit VRFRequested(users[0], 1, bytes32(0));

        bytes32 requestId = kandilli.retroSnuffCandle(auctionId);
        vm.stopPrank();
        vrfCoordinatorMock.callBackWithRandomness(requestId, vrf, address(kandilli));
    }

    function _proposeWinners(
        uint256 auctionId,
        uint256 startTime,
        bool callPropose
    ) private returns (ProposeWinnersResult memory result) {
        result.bids = kandilli.getAuctionBids(auctionId, 0, 0);
        result.snuffTime = kandilli.getAuctionCandleSnuffedTime(auctionId);
        uint256 bidCount = 0;

        // Count bids sent before snuff time.
        for (uint256 i = 0; i < result.bids.length; i++) {
            if (startTime + result.bids[i].timePassedFromStart < result.snuffTime) {
                bidCount++;
            }
        }

        //Bid with index to sort with for same amount
        result.nBids = new IKandilli.KandilBidWithIndex[](bidCount);
        uint256 ni = 0;
        for (uint256 i = 0; i < result.bids.length; i++) {
            if (startTime + result.bids[i].timePassedFromStart < result.snuffTime) {
                result.nBids[ni++] = IKandilli.KandilBidWithIndex(
                    result.bids[i].bidder,
                    result.bids[i].timePassedFromStart,
                    result.bids[i].bidAmount,
                    result.bids[i].isProcessed,
                    uint32(i)
                );
            }
        }
        result.nBids = Helpers.sortBids(result.nBids);
        result.numWinners = kandilli.getAuctionWinnerCount(auctionId);
        result.vrfResult = kandilli.getAuctionVRF(auctionId);
        uint256 depositAmount = kandilli.getAuctionRequiredWinnersProposalDeposit(auctionId);
        if (result.numWinners > result.nBids.length) {
            result.numWinners = result.nBids.length;
        }
        result.winnerBidIds = new uint32[](result.numWinners);
        for (uint256 i = 0; i < result.numWinners; i++) {
            result.winnerBidIds[i] = uint32(result.nBids[i].index);
        }
        result.hash = keccak256(abi.encodePacked(result.winnerBidIds, result.vrfResult));

        if (callPropose) {
            kandilli.proposeWinners{value: depositAmount}(auctionId, result.winnerBidIds, result.hash);
        }
    }
}

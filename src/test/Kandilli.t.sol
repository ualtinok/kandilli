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
import {Strings} from "../../lib/openzeppelin-contracts/contracts/utils/Strings.sol";

struct ProposeWinnersResult {
    bytes32 hash;
    uint32[] winnerBidIds;
    IKandilli.KandilBidWithIndex[] nBids;
    IKandilli.KandilBid[] bids;
    uint256 vrfResult;
    uint256 numWinners;
    uint256 snuffTime;
    uint64 totalBidAmount;
}

contract KandilliTest is DSTest {
    using Strings for uint256;

    event AuctionStarted(uint256 auctionId, uint256 startTime);
    event AuctionBid(address indexed sender, uint256 indexed auctionId, uint256 indexed bidId, uint256 value);
    event AuctionBidIncrease(address indexed sender, uint256 indexed auctionId, uint256 indexed bidId, uint256 value);
    event AuctionWinnersProposed(address indexed sender, uint256 indexed auctionId, bytes32 hash);
    event CandleSnuffed(address indexed sender, uint256 indexed auctionId, bytes32 requestId);
    event WinningBidClaimed(address indexed sender, uint256 indexed auctionId, uint256 bidId, address claimedto);
    event LostBidWithdrawn(address indexed sender, uint256 indexed auctionId, uint256 indexed bidId);
    event WinnersProposalBountyClaimed(address indexed sender, uint256 indexed auctionId, uint256 amount);
    event SnuffBountyClaimed(address indexed sender, uint256 indexed auctionId, uint256 amount);
    event ChallengeSucceded(address indexed sender, uint256 indexed auctionId, uint256 reason);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    Vm internal immutable vm = Vm(HEVM_ADDRESS);

    Utilities internal utils;
    Kandilli internal kandilli;
    MockAuctionableToken internal mockAuctionableToken;
    LinkTokenMock internal linkToken;
    VRFCoordinatorMock internal vrfCoordinatorMock;
    WETH internal weth;
    address payable[] internal users;
    address payable internal alice;
    address payable internal bob;

    uint64 internal winnersProposalDeposit = (1 ether) / (1 gwei); // 1 ether
    uint32 internal maxNumWinners = 32; // 32 users
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
    //uint256 internal randomE = 65767386873957718740268074328995333784005072918202063793299981458799458871201; // single bid, 0 winners
    uint8 internal maxBountyMultiplier = 10;
    uint8 internal snuffPercentage = 30;

    bool userPaysLink = false;

    // This is to get a random number via FFI. Can comment out and enable ffi via (test --ffi or via toml)
    // Requires nodejs installed
    bool randomViaFFI = false;

    uint256 maxTestBidCount = 200;

    function setUp() public {
        utils = new Utilities();
        if (randomViaFFI) {
            randomE = utils.getRandomNumber();
        }
        users = utils.createUsers(100);
        alice = users[0];
        bob = users[1];
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
            maxNumWinners,
            maxBountyMultiplier,
            snuffPercentage,
            false
        );
        uint32[] memory initialBidAmounts = new uint32[](10);
        for (uint256 i = 0; i < 10; i++) {
            initialBidAmounts[i] = 100;
        }
        vm.prank(utils.getNamedUser("deployer"));
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

    function testInit() public {
        vm.expectRevert("Ownable: caller is not the owner");
        kandilli.init();
        vm.startPrank(utils.getNamedUser("deployer"));
        kandilli.init();
        vm.expectRevert(abi.encodeWithSignature("AlreadyInitialized()"));
        kandilli.init();
    }

    function testBids(uint256 randomE) public {
        vm.prank(utils.getNamedUser("deployer"));
        kandilli.init();
        uint256 auctionId = 1;
        uint256 startTime = kandilli.getAuctionStartTime(auctionId);
        vm.prank(alice);
        vm.expectEmit(true, true, true, true);
        emit AuctionBid(alice, auctionId, 0, 1 ether);
        kandilli.addBidToAuction{value: 1 ether}(auctionId);
        vm.prank(bob);
        vm.expectEmit(true, true, true, true);
        emit AuctionBid(bob, auctionId, 1, 1 ether);
        kandilli.addBidToAuction{value: 1 ether}(auctionId);

        uint256 minBidAmount = kandilli.getAuctionMinimumBidAmount(auctionId);
        // Fail if minimum bid amount is not met.
        vm.expectRevert(abi.encodeWithSignature("MinimumBidAmountNotMet()"));
        kandilli.addBidToAuction{value: minBidAmount - (1 gwei)}(auctionId);

        // Fail if auction doesn't exist
        vm.expectRevert(abi.encodeWithSignature("AuctionIsNotRunning()"));
        kandilli.addBidToAuction{value: 1 ether}(99);

        // Fail if lower then gwei precision bid
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("BidWithPrecisionLowerThanGwei()"));
        kandilli.addBidToAuction{value: 1 wei}(auctionId);

        vm.prank(alice);
        vm.warp(startTime + auctionTotalDuration + 1);
        vm.expectRevert(abi.encodeWithSignature("CannotBidAfterAuctionEndTime()"));
        kandilli.addBidToAuction{value: 1 ether}(auctionId);
    }

    function testIncreaseBid(uint256 randomE) public {
        vm.prank(utils.getNamedUser("deployer"));
        kandilli.init();
        uint256 auctionId = 1;
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
        uint256 randomE,
        uint16 timePassed,
        bool isLinkRequired
    ) public {
        /*        uint256 randomE = 65767386873957718740268074328995333784005072918202063793299981458799458871201;
        uint16 timePassed = 0;
        bool isLinkRequired = false;*/
        vm.startPrank(utils.getNamedUser("deployer"));
        kandilli.setAuctionRequiresLink(isLinkRequired);
        kandilli.init();
        vm.stopPrank();

        uint256 auctionId = 1;
        uint256 numBids = randomE % maxTestBidCount;
        uint256 startTime = kandilli.getAuctionStartTime(auctionId);
        uint256 maxNumWinners = kandilli.getAuctionMaxWinnerCount(auctionId);
        console.log("maxNumWinners: ", maxNumWinners);
        console.log("numBids: ", numBids);
        console.log("bal: ", address(kandilli).balance);

        bool allBidsAreWinners = numBids <= maxNumWinners;
        _sendBids(auctionId, numBids, startTime, randomE);
        console.log("bal3: ", address(kandilli).balance);

        vm.expectRevert(abi.encodeWithSignature("CannotSnuffCandleBeforeDefiniteEndTime()"));
        kandilli.retroSnuffCandle(1);

        vm.expectRevert(abi.encodeWithSignature("CannotSnuffCandleForNotRunningAuction()"));
        kandilli.retroSnuffCandle(99);

        //uint256 aliceOldBalance = alice.balance;
        vm.warp(startTime + auctionTotalDuration + timePassed);
        /*        uint256 bounty = kandilli.getAuctionRetroSnuffBounty(auctionId);
        uint256 minimumAmountCollected = kandilli.getAuctionMinimumBidAmount(auctionId) * (1 gwei) * numBids;
        bounty = bounty < minimumAmountCollected ? bounty : minimumAmountCollected;
        assertLe(bounty, uint256(maxBountyMultiplier) * uint256(retroSnuffGas) * (100 gwei));*/

        if (numBids == 0) {
            vm.startPrank(alice);
            vm.expectEmit(true, false, false, true);
            emit CandleSnuffed(alice, auctionId, bytes32(0));
            bytes32 reqId = kandilli.retroSnuffCandle(auctionId);
            assertEq(reqId, bytes32(0));
            IKandilli.KandilState state = kandilli.getAuctionState(auctionId);
            assertEq(uint256(state), uint256(IKandilli.KandilState.EndedWithoutBids));
            vm.stopPrank();
            return;
        }

        if (isLinkRequired) {
            vm.prank(bob);
            vm.expectRevert(abi.encodeWithSignature("UserDontHaveEnoughLinkToAskForVRF()"));
            kandilli.retroSnuffCandle(auctionId);

            vm.startPrank(alice);
            vm.expectRevert("ERC20: transfer amount exceeds allowance");
            kandilli.retroSnuffCandle(auctionId);
            vm.stopPrank();
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
            emit CandleSnuffed(alice, auctionId, bytes32(0));
            bytes32 requestId = kandilli.retroSnuffCandle(auctionId);
            vrfCoordinatorMock.callBackWithRandomness(requestId, randomE, address(kandilli));
            //uint256 aliceNewBalance = alice.balance;
            //assertEq(aliceNewBalance - aliceOldBalance, bounty);
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

        vm.expectRevert(abi.encodeWithSignature("CannotClaimSnuffBountyBeforeWinnersProposed()"));
        kandilli.claimSnuffBounty(auctionId);

        uint256 currentSnuffBounty = kandilli.getAuctionRetroSnuffBounty(auctionId);
        assertEq(currentSnuffBounty, 0);

        ProposeWinnersResult memory pwr = _proposeWinners(auctionId, startTime, true);
        console.log("tot", pwr.totalBidAmount);
        console.log("numWinner", pwr.numWinners);
        vm.expectRevert(abi.encodeWithSignature("CannotClaimSnuffBountyBeforeIfNotSnuffer()"));
        kandilli.claimSnuffBounty(auctionId);

        vm.startPrank(alice);

        vm.expectRevert(abi.encodeWithSignature("CannotClaimSnuffBountyBeforeChallengePeriodIsOver()"));
        kandilli.claimSnuffBounty(auctionId);

        uint256 proposalTime = kandilli.getAuctionWinnerProposalTime(auctionId);
        vm.warp(proposalTime + fraudChallengePeriod + 1);

        currentSnuffBounty = kandilli.getAuctionRetroSnuffBounty(auctionId);
        if (currentSnuffBounty > 0) {
            uint256 beforeBalance = alice.balance;
            kandilli.claimSnuffBounty(auctionId);
            uint256 afterBalance = alice.balance;
            assertEq(afterBalance - beforeBalance, currentSnuffBounty);
        }
    }

    function testProposeWinners(uint256 randomE) public {
        //uint256 randomE = 1858916283958370368913553293944955234632628839575658048919750774306277050000;
        vm.prank(utils.getNamedUser("deployer"));
        kandilli.init();

        uint256 auctionId = 1;
        uint256 depositAmount = kandilli.getAuctionRequiredWinnersProposalDeposit(auctionId);
        uint256 startTime = kandilli.getAuctionStartTime(auctionId);
        uint256 numBids = randomE % maxTestBidCount;
        // Fail when posting winners before candle snuffed
        {
            uint32[] memory dummyWinnerIds = new uint32[](3);
            bytes32 dummyHash = keccak256(abi.encodePacked("x"));

            dummyWinnerIds[0] = 3;
            dummyWinnerIds[1] = 3;
            dummyWinnerIds[2] = 3;
            vm.expectRevert(abi.encodeWithSignature("CannotProposeWinnersBeforeVRFSetOrWhenWinnersAlreadyPosted()"));
            kandilli.proposeWinners{value: depositAmount}(auctionId, dummyWinnerIds, dummyHash, 0);
        }

        _sendBids(auctionId, numBids, startTime, randomE);
        _snuffCandle(auctionId, randomE, startTime);

        IKandilli.KandilState state = kandilli.getAuctionState(auctionId);

        // No bids
        if (state == IKandilli.KandilState.EndedWithoutBids) {
            uint32[] memory dummyWinnerIds = new uint32[](3);
            bytes32 dummyHash = keccak256(abi.encodePacked("x"));

            dummyWinnerIds[0] = 3;
            dummyWinnerIds[1] = 3;
            dummyWinnerIds[2] = 3;
            vm.expectRevert(abi.encodeWithSignature("CannotProposeWinnersBeforeVRFSetOrWhenWinnersAlreadyPosted()"));
            kandilli.proposeWinners{value: depositAmount}(auctionId, dummyWinnerIds, dummyHash, 0);

            return;
        }
        assertEq(uint256(state), uint256(IKandilli.KandilState.VRFSet));
        ProposeWinnersResult memory pwr = _proposeWinners(auctionId, startTime, false);
        // Fail when posting winners with wrong hash
        vm.expectRevert(abi.encodeWithSignature("IncorrectHashForWinnerBids()"));
        kandilli.proposeWinners{value: depositAmount}(
            auctionId,
            pwr.winnerBidIds,
            keccak256(abi.encodePacked("x")),
            pwr.totalBidAmount
        );

        bytes32 hash = keccak256(abi.encodePacked(pwr.winnerBidIds, pwr.vrfResult));

        // Fail when posting winners with wrong deposit amount
        vm.expectRevert(abi.encodeWithSignature("DepositAmountForWinnersProposalNotMet()"));
        kandilli.proposeWinners{value: 1 wei}(auctionId, pwr.winnerBidIds, pwr.hash, pwr.totalBidAmount);

        // Succeed to post winners and check balance
        {
            uint256 aliceBalanceBefore = alice.balance;
            vm.prank(alice);
            vm.expectEmit(true, false, false, true);
            emit AuctionWinnersProposed(alice, auctionId, pwr.hash);
            kandilli.proposeWinners{value: depositAmount}(auctionId, pwr.winnerBidIds, pwr.hash, pwr.totalBidAmount);
            uint256 aliceBalanceAfter = alice.balance;
            assertEq(aliceBalanceBefore - aliceBalanceAfter, depositAmount);
        }

        // Fail when posting winners a second time
        {
            vm.expectRevert(abi.encodeWithSignature("CannotProposeWinnersBeforeVRFSetOrWhenWinnersAlreadyPosted()"));
            kandilli.proposeWinners{value: depositAmount}(auctionId, pwr.winnerBidIds, pwr.hash, pwr.totalBidAmount);
        }
        //uint256 totalPaidProposalBounty = kandilli.getAuctionWinnersProposalBounty(auctionId);
    }

    function testClaimToken(uint256 randomE) public {
        vm.prank(utils.getNamedUser("deployer"));
        kandilli.init();

        //uint256 randomE = 95275698087996319157942145645038655316366211765455253903736262480567932210200;
        uint256 auctionId = 1;
        uint256 startTime = kandilli.getAuctionStartTime(auctionId);
        uint256 numBids = (randomE % maxTestBidCount) + 1; // Need at least 1 bid to claim token.

        uint32[] memory dummyWinnerIds = new uint32[](3);
        _sendBids(auctionId, numBids, startTime, randomE);
        _snuffCandle(auctionId, randomE, startTime);

        vm.expectRevert(abi.encodeWithSignature("CannotClaimAuctionItemBeforeWinnersProposed()"));
        kandilli.claimWinningBid(auctionId, bytes32(0), dummyWinnerIds, 0);

        ProposeWinnersResult memory pwr = _proposeWinners(auctionId, startTime, true);

        if (pwr.winnerBidIds.length == 0) {
            // TODO: vm.assume
            return;
        }
        vm.expectRevert(abi.encodeWithSignature("CannotClaimAuctionItemBeforeChallengePeriodEnds()"));
        kandilli.claimWinningBid(auctionId, pwr.hash, pwr.winnerBidIds, 0);

        uint256 proposalTime = kandilli.getAuctionWinnerProposalTime(auctionId);
        vm.warp(proposalTime + fraudChallengePeriod + 1);

        vm.expectRevert(abi.encodeWithSignature("BidIdDoesntExist()"));
        kandilli.claimWinningBid(auctionId, pwr.hash, pwr.winnerBidIds, pwr.winnerBidIds.length);

        bytes32 dummyHash = keccak256(abi.encodePacked(dummyWinnerIds, pwr.vrfResult));
        dummyWinnerIds[0] = 0;
        dummyWinnerIds[1] = 4;
        dummyWinnerIds[2] = 1;
        vm.expectRevert(abi.encodeWithSignature("WinnerProposalDataDoesntHaveCorrectHash()"));
        kandilli.claimWinningBid(auctionId, dummyHash, dummyWinnerIds, 0);

        dummyHash = keccak256(abi.encodePacked(dummyWinnerIds, pwr.vrfResult));
        vm.expectRevert(abi.encodeWithSignature("WinnerProposalHashDoesntMatchPostedHash()"));
        kandilli.claimWinningBid(auctionId, dummyHash, dummyWinnerIds, 0);

        uint256 toClaimId = randomE % pwr.winnerBidIds.length;

        address payable someOtherUser = utils.getNamedUser("someOtherUser");
        uint256 someOtherUserBeforeBalance = someOtherUser.balance;
        vm.prank(someOtherUser);
        vm.expectEmit(true, false, false, true);
        emit WinningBidClaimed(someOtherUser, 1, pwr.winnerBidIds[toClaimId], pwr.bids[pwr.winnerBidIds[toClaimId]].bidder);
        kandilli.claimWinningBid(auctionId, pwr.hash, pwr.winnerBidIds, toClaimId);
        uint256 claimBounty = kandilli.getClaimWinningBidBounty(auctionId);

        // Check if someOtherUser received right bounty.
        assertEq(claimBounty, someOtherUser.balance - someOtherUserBeforeBalance, "Received bounty for snuff is incorrect");

        // Check if bidder received token.
        assertEq(mockAuctionableToken.balanceOf(pwr.bids[pwr.winnerBidIds[toClaimId]].bidder), 1, "Bidder did not receive token");

        // Check that someOtherUser did not receive any tokens.
        assertEq(mockAuctionableToken.balanceOf(someOtherUser), 0, "SomeOtherUser received tokens, when she shouldn't have");

        // Fail to claim tokens that are already claimed.
        vm.expectRevert(abi.encodeWithSignature("BidAlreadyClaimed()"));
        kandilli.claimWinningBid(auctionId, pwr.hash, pwr.winnerBidIds, toClaimId);
    }

    function testWithdrawBid(uint256 randomE) public {
        vm.prank(utils.getNamedUser("deployer"));
        kandilli.init();

        uint256 auctionId = 1;
        uint256 startTime = kandilli.getAuctionStartTime(auctionId);

        _sendBids(auctionId, 100, startTime, randomE);
        _snuffCandle(auctionId, randomE, startTime);

        ProposeWinnersResult memory pwr = _proposeWinners(auctionId, startTime, true);

        uint256 proposalTime = kandilli.getAuctionWinnerProposalTime(auctionId);
        vm.warp(proposalTime + fraudChallengePeriod + 1);

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

        vm.expectEmit(true, true, false, true);
        emit LostBidWithdrawn(pwr.nBids[pwr.numWinners + 1].bidder, auctionId, pwr.nBids[pwr.numWinners].index);
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
        vm.prank(utils.getNamedUser("deployer"));
        kandilli.init();

        //uint256 randomE = 109687285319737427546864928704912123564621911379828527642653841607651681983601;

        uint256 auctionId = 1;
        uint256 startTime = kandilli.getAuctionStartTime(auctionId);
        uint256 depositAmount = kandilli.getAuctionRequiredWinnersProposalDeposit(auctionId);
        uint256 numBids = randomE % maxTestBidCount;
        _sendBids(auctionId, numBids, startTime, randomE);
        _snuffCandle(auctionId, randomE, startTime);
        IKandilli.KandilState state = kandilli.getAuctionState(auctionId);
        if (state == IKandilli.KandilState.EndedWithoutBids) {
            //TODO: vm.assume
            return;
        }
        ProposeWinnersResult memory pwr = _proposeWinners(auctionId, startTime, false);
        // Send more winner bids than total bid count
        {
            uint32[] memory dummyWinnerIds = new uint32[](pwr.bids.length + 1);
            bytes32 dummyHash = keccak256(abi.encodePacked(dummyWinnerIds, pwr.vrfResult));
            kandilli.proposeWinners{value: depositAmount}(auctionId, dummyWinnerIds, dummyHash, pwr.totalBidAmount);
            address challenger = utils.getNamedUser("challenger");

            vm.expectEmit(true, false, false, true);
            emit ChallengeSucceded(challenger, auctionId, 1);
            vm.prank(challenger);
            uint256 chalBalBefore = challenger.balance;
            kandilli.challengeProposedWinners(auctionId, dummyWinnerIds, dummyHash, 1);
            uint256 chalBalAfter = challenger.balance;
            assertEq(chalBalAfter, chalBalBefore + depositAmount, "Challenger didn't receive enough bounty");
        }

        // Send duplicate winner bids
        if (numBids > 2) {
            uint32[] memory dummyWinnerIds = new uint32[](3);
            dummyWinnerIds[0] = 5;
            dummyWinnerIds[1] = 3;
            dummyWinnerIds[2] = 5;
            bytes32 dummyHash = keccak256(abi.encodePacked(dummyWinnerIds, pwr.vrfResult));
            kandilli.proposeWinners{value: depositAmount}(auctionId, dummyWinnerIds, dummyHash, pwr.totalBidAmount);
            address challenger = utils.getNamedUser("challenger");

            vm.expectEmit(true, false, false, true);
            emit ChallengeSucceded(challenger, auctionId, 2);
            vm.prank(challenger);
            uint256 chalBalBefore = challenger.balance;
            kandilli.challengeProposedWinners(auctionId, dummyWinnerIds, dummyHash, 2);
            uint256 chalBalAfter = challenger.balance;
            assertEq(chalBalAfter, chalBalBefore + depositAmount, "Challenger didn't receive enough bounty");
        }

        // Propose bigger winner index than total bid count.
        if (pwr.numWinners > 0) {
            uint32[] memory dummyWinnerIds = new uint32[](pwr.numWinners);
            for (uint256 i = 0; i < pwr.numWinners; i++) {
                dummyWinnerIds[i] = pwr.winnerBidIds[i];
            }
            dummyWinnerIds[0] = uint32(pwr.bids.length);
            bytes32 dummyHash = keccak256(abi.encodePacked(dummyWinnerIds, pwr.vrfResult));
            kandilli.proposeWinners{value: depositAmount}(auctionId, dummyWinnerIds, dummyHash, pwr.totalBidAmount);
            address challenger = utils.getNamedUser("challenger");

            vm.expectEmit(true, false, false, true);
            emit ChallengeSucceded(challenger, auctionId, 3);
            vm.prank(challenger);
            uint256 chalBalBefore = challenger.balance;
            kandilli.challengeProposedWinners(auctionId, dummyWinnerIds, dummyHash, 0xFFFFFFFF);
            uint256 chalBalAfter = challenger.balance;
            assertEq(chalBalAfter, chalBalBefore + depositAmount, "Challenger didn't receive enough bounty");
        }

        // Send bid which is after snuff time
        {
            uint32 bidAfterSnuff = 0xFFFFFFFF;
            for (uint256 i = 0; i < pwr.bids.length; i++) {
                if (startTime + uint256(uint32(pwr.bids[i].timePassedFromStart)) >= pwr.snuffTime) {
                    bidAfterSnuff = uint32(i);
                }
            }
            if (bidAfterSnuff == 0xFFFFFFFF) {
                return;
            }
            uint32[] memory dummyWinnerIds = new uint32[](1);
            dummyWinnerIds[0] = bidAfterSnuff;
            bytes32 dummyHash = keccak256(abi.encodePacked(dummyWinnerIds, pwr.vrfResult));
            kandilli.proposeWinners{value: depositAmount}(auctionId, dummyWinnerIds, dummyHash, pwr.totalBidAmount);
            address challenger = utils.getNamedUser("challenger");

            vm.expectEmit(true, false, false, true);
            emit ChallengeSucceded(challenger, auctionId, 4);
            vm.prank(challenger);
            uint256 chalBalBefore = challenger.balance;
            kandilli.challengeProposedWinners(auctionId, dummyWinnerIds, dummyHash, 0xFFFFFFFF);
            uint256 chalBalAfter = challenger.balance;
            assertEq(chalBalAfter, chalBalBefore + depositAmount, "Challenger didn't receive enough bounty");
        }

        // Send wrong total amount
        if (pwr.totalBidAmount > 0) {
            kandilli.proposeWinners{value: depositAmount}(auctionId, pwr.winnerBidIds, pwr.hash, pwr.totalBidAmount - 1);
            address challenger = utils.getNamedUser("challenger");
            vm.expectEmit(true, false, false, true);
            emit ChallengeSucceded(challenger, auctionId, 6);
            vm.prank(challenger);
            uint256 chalBalBefore = challenger.balance;
            kandilli.challengeProposedWinners(auctionId, pwr.winnerBidIds, pwr.hash, 0xFFFFFFFF);
            /*uint256 chalBalAfter = challenger.balance;
            assertEq(chalBalAfter, chalBalBefore + depositAmount, "Challenger didn't receive enough bounty");*/
        }

        // Send bad list #1:  last 2 items swapped
        if (pwr.numWinners > 1) {
            uint32[] memory dummyWinnerIds = new uint32[](pwr.numWinners);
            for (uint256 i = 0; i < pwr.numWinners; i++) {
                dummyWinnerIds[i] = uint32(pwr.nBids[i].index);
            }

            (dummyWinnerIds[pwr.numWinners - 1], dummyWinnerIds[pwr.numWinners - 2]) = (
                dummyWinnerIds[pwr.numWinners - 2],
                dummyWinnerIds[pwr.numWinners - 1]
            );

            bytes32 dummyHash = keccak256(abi.encodePacked(dummyWinnerIds, pwr.vrfResult));
            kandilli.proposeWinners{value: depositAmount}(auctionId, dummyWinnerIds, dummyHash, pwr.totalBidAmount);
            address challenger = utils.getNamedUser("challenger");

            vm.expectEmit(true, false, false, true);
            emit ChallengeSucceded(challenger, auctionId, 7);
            vm.prank(challenger);
            uint256 chalBalBefore = challenger.balance;
            kandilli.challengeProposedWinners(auctionId, dummyWinnerIds, dummyHash, 0xFFFFFFFF);
            uint256 chalBalAfter = challenger.balance;
            assertEq(chalBalAfter, chalBalBefore + depositAmount, "Challenger didn't receive enough bounty");
        }

        // Send bad list #2: Swap first loser with last winner.
        if (pwr.numWinners > numBids) {
            uint32[] memory dummyWinnerIds = new uint32[](pwr.numWinners);
            for (uint256 i = 0; i < pwr.numWinners - 1; i++) {
                dummyWinnerIds[i] = uint32(pwr.nBids[i].index);
            }
            dummyWinnerIds[pwr.numWinners - 1] = uint32(pwr.nBids[pwr.numWinners].index);
            bytes32 dummyHash = keccak256(abi.encodePacked(dummyWinnerIds, pwr.vrfResult));
            kandilli.proposeWinners{value: depositAmount}(auctionId, dummyWinnerIds, dummyHash, pwr.totalBidAmount);
            address challenger = utils.getNamedUser("challenger");

            vm.expectEmit(true, false, false, true);
            emit ChallengeSucceded(challenger, auctionId, 7);
            vm.prank(challenger);
            uint256 chalBalBefore = challenger.balance;
            kandilli.challengeProposedWinners(auctionId, dummyWinnerIds, dummyHash, uint32(pwr.nBids[pwr.numWinners - 1].index));
            uint256 chalBalAfter = challenger.balance;
            assertEq(chalBalAfter, chalBalBefore + depositAmount, "Challenger didn't receive enough bounty");
        }

        // Try to repropose winners after successful fraud proof.
        _proposeWinners(auctionId, startTime, true);

        vm.expectRevert(abi.encodeWithSignature("ChallengeFailedWinnerProposalIsCorrect()"));
        kandilli.challengeProposedWinners(auctionId, pwr.winnerBidIds, pwr.hash, 0xFFFFFFFF);
    }

    function testChallengeWinnersProposalFailures(uint256 randomE) public {
        vm.prank(utils.getNamedUser("deployer"));
        kandilli.init();
        //uint256 randomE = 4499550098297379889107541569912050205441959294117414913041628694394132133202;
        uint256 auctionId = 1;
        uint256 startTime = kandilli.getAuctionStartTime(auctionId);
        uint256 depositAmount = kandilli.getAuctionRequiredWinnersProposalDeposit(auctionId);
        uint256 numBids = randomE % maxTestBidCount;
        _sendBids(auctionId, numBids, startTime, randomE);
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

        IKandilli.KandilState state = kandilli.getAuctionState(auctionId);
        if (state == IKandilli.KandilState.EndedWithoutBids) {
            //TODO: vm.assume
            return;
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

        vm.prank(utils.getNamedUser("proposer"));
        vm.expectRevert(abi.encodeWithSignature("CannotChallengeSelfProposal()"));
        kandilli.challengeProposedWinners(auctionId, pwr.winnerBidIds, pwr.hash, 0);

        if (pwr.numWinners == 0) {
            // TODO: vm.assume
            return;
        }

        vm.startPrank(utils.getNamedUser("challenger"));
        vm.expectRevert(abi.encodeWithSignature("ChallengeFailedBidIdToIncludeAlreadyInWinnerList()"));
        kandilli.challengeProposedWinners(auctionId, pwr.winnerBidIds, pwr.hash, pwr.winnerBidIds[0]);

        vm.expectRevert(abi.encodeWithSignature("ChallengeFailedBidIdToIncludeIsNotInBidList()"));
        kandilli.challengeProposedWinners(auctionId, pwr.winnerBidIds, pwr.hash, uint32(pwr.bids.length));

        vm.expectRevert(abi.encodeWithSignature("ChallengeFailedWinnerProposalIsCorrect()"));
        kandilli.challengeProposedWinners(auctionId, pwr.winnerBidIds, pwr.hash, 0xFFFFFFFF);

        // Fail to challenge after challenge period
        uint256 proposalTime = kandilli.getAuctionWinnerProposalTime(auctionId);
        vm.warp(proposalTime + fraudChallengePeriod + 1);
        vm.expectRevert(abi.encodeWithSignature("CannotChallengeWinnersProposalAfterChallengePeriodIsOver()"));
        kandilli.challengeProposedWinners(auctionId, pwr.winnerBidIds, pwr.hash, 0);
        vm.stopPrank();
    }

    function testSort() public {
        IKandilli.KandilBidWithIndex[] memory nBids = new IKandilli.KandilBidWithIndex[](15);
        nBids[0] = IKandilli.KandilBidWithIndex(users[0], 0, 100, 0);
        nBids[1] = IKandilli.KandilBidWithIndex(users[1], 0, 150, 1);
        nBids[2] = IKandilli.KandilBidWithIndex(users[2], 0, 150, 2);
        nBids[3] = IKandilli.KandilBidWithIndex(users[3], 0, 150, 3);
        nBids[4] = IKandilli.KandilBidWithIndex(users[4], 0, 150, 4);
        nBids[5] = IKandilli.KandilBidWithIndex(users[5], 0, 500, 9);
        nBids[6] = IKandilli.KandilBidWithIndex(users[6], 0, 500, 6);
        nBids[7] = IKandilli.KandilBidWithIndex(users[7], 0, 1500, 7);
        nBids[8] = IKandilli.KandilBidWithIndex(users[8], 0, 100, 8);
        nBids[9] = IKandilli.KandilBidWithIndex(users[9], 0, 500, 5);
        nBids[10] = IKandilli.KandilBidWithIndex(users[10], 0, 120, 10);
        nBids[11] = IKandilli.KandilBidWithIndex(users[11], 0, 100, 13);
        nBids[12] = IKandilli.KandilBidWithIndex(users[12], 0, 100, 11);
        nBids[13] = IKandilli.KandilBidWithIndex(users[12], 0, 100, 12);
        nBids[14] = IKandilli.KandilBidWithIndex(users[12], 0, 1501, 14);

        nBids = Helpers.sortBids(nBids);

        IKandilli.KandilBidWithIndex[] memory expectedBids = new IKandilli.KandilBidWithIndex[](15);
        expectedBids[0] = IKandilli.KandilBidWithIndex(users[12], 0, 1501, 14);
        expectedBids[1] = IKandilli.KandilBidWithIndex(users[7], 0, 1500, 7);
        expectedBids[2] = IKandilli.KandilBidWithIndex(users[9], 0, 500, 5);
        expectedBids[3] = IKandilli.KandilBidWithIndex(users[6], 0, 500, 6);
        expectedBids[4] = IKandilli.KandilBidWithIndex(users[5], 0, 500, 9);
        expectedBids[5] = IKandilli.KandilBidWithIndex(users[1], 0, 150, 1);
        expectedBids[6] = IKandilli.KandilBidWithIndex(users[2], 0, 150, 2);
        expectedBids[7] = IKandilli.KandilBidWithIndex(users[3], 0, 150, 3);
        expectedBids[8] = IKandilli.KandilBidWithIndex(users[4], 0, 150, 4);
        expectedBids[9] = IKandilli.KandilBidWithIndex(users[10], 0, 120, 10);
        expectedBids[10] = IKandilli.KandilBidWithIndex(users[0], 0, 100, 0);
        expectedBids[11] = IKandilli.KandilBidWithIndex(users[8], 0, 100, 8);
        expectedBids[12] = IKandilli.KandilBidWithIndex(users[12], 0, 100, 11);
        expectedBids[13] = IKandilli.KandilBidWithIndex(users[12], 0, 100, 12);
        expectedBids[14] = IKandilli.KandilBidWithIndex(users[11], 0, 100, 13);

        assertEq(keccak256(abi.encode(nBids)), keccak256(abi.encode(expectedBids)));
    }

    function testBidPaging() public {
        vm.prank(utils.getNamedUser("deployer"));
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

    function testMoveFunds(uint256 randomE) public {
        vm.prank(utils.getNamedUser("deployer"));
        kandilli.init();

        //uint256 randomE = 9665110016001107365961736065161865292364745277800064029878957631900366855401;
        uint256 auctionId = 1;
        uint256 startTime = kandilli.getAuctionStartTime(auctionId);
        uint256 numBids = randomE % maxTestBidCount;

        _sendBids(auctionId, numBids, startTime, randomE);
        _snuffCandle(auctionId, randomE, startTime);
        if (kandilli.getAuctionState(auctionId) == IKandilli.KandilState.EndedWithoutBids) {
            //TODO: vm.assume
            return;
        }
        vm.expectRevert(abi.encodeWithSignature("CannotMoveFundsBeforeWinnersProposed()"));
        kandilli.moveAuctionFundsToOwner(auctionId);
        ProposeWinnersResult memory pwr = _proposeWinners(auctionId, startTime, true);

        vm.expectRevert(abi.encodeWithSignature("CannotMoveFundsBeforeChallengePeriodEnds()"));
        kandilli.moveAuctionFundsToOwner(auctionId);

        uint256 proposalTime = kandilli.getAuctionWinnerProposalTime(auctionId);
        vm.warp(proposalTime + fraudChallengePeriod + 1);

        if (pwr.numWinners == 0) {
            //TODO: vm.assume
            return;
        }

        uint256 bidTotal = 0;
        vm.startPrank(utils.getNamedUser("bot"));
        for (uint256 i = 0; i < pwr.winnerBidIds.length; i++) {
            bidTotal += (pwr.bids[pwr.winnerBidIds[i]].bidAmount) * (1 gwei);
            kandilli.claimWinningBid(auctionId, pwr.hash, pwr.winnerBidIds, i);
        }
        vm.stopPrank();
        IKandilli.KandilBid[] memory bids = kandilli.getAuctionBids(auctionId, 0, 0);
        for (uint256 i = 0; i < bids.length; i++) {
            if (bids[i].timePassedFromStart != -1) {
                vm.prank(bids[i].bidder);
                kandilli.withdrawLostBid(auctionId, i, pwr.hash, pwr.winnerBidIds);
            }
        }

        uint256 totalPaidSnuffBounty = kandilli.getAuctionRetroSnuffBounty(auctionId);
        uint256 totalPaidProposalBounty = kandilli.getAuctionWinnersProposalBounty(auctionId);

        if (totalPaidSnuffBounty > 0) {
            vm.prank(utils.getNamedUser("snuffer"));
            kandilli.claimSnuffBounty(auctionId);
        }
        if (totalPaidProposalBounty > 0) {
            vm.prank(utils.getNamedUser("proposer"));
            kandilli.claimWinnersProposalBounty(auctionId);
        }

        {
            uint256 minB = kandilli.getAuctionMinimumBidAmount(auctionId);
            uint256 totalPaidClaimBounty = pwr.winnerBidIds.length * minB;
            if (pwr.totalBidAmount * (1 gwei) > totalPaidSnuffBounty + totalPaidProposalBounty + totalPaidClaimBounty) {
                uint256 ownerBalanceBefore = utils.getNamedUser("deployer").balance;
                kandilli.moveAuctionFundsToOwner(auctionId);
                uint256 ownerBalanceAfter = utils.getNamedUser("deployer").balance;

                assertEq(
                    bidTotal - totalPaidClaimBounty - totalPaidSnuffBounty - totalPaidProposalBounty,
                    ownerBalanceAfter - ownerBalanceBefore
                );
                assertEq(address(kandilli).balance, 0);
            } else {
                assertEq(address(kandilli).balance, 0);
                vm.expectRevert(abi.encodeWithSignature("EthTransferFailedDestOrAmountZero()"));
                kandilli.moveAuctionFundsToOwner(auctionId);
            }
        }
    }

    function testFullAuction() public {
        vm.prank(utils.getNamedUser("deployer"));
        kandilli.init();

        uint256 auctionId = 1;
        uint256 startTime = kandilli.getAuctionStartTime(auctionId);
        uint256 numBids = 500;

        _sendBids(auctionId, numBids, startTime, randomE);
        IKandilli.KandilBid[] memory bids = kandilli.getAuctionBids(auctionId, 0, 0);

        for (uint256 i = 0; i < bids.length; i++) {
            vm.prank(bids[i].bidder);
            kandilli.increaseAmountOfBid{value: (1 gwei)}(auctionId, i);
        }
        _snuffCandle(auctionId, randomE, startTime);

        ProposeWinnersResult memory pwr = _proposeWinners(auctionId, startTime, true);

        uint256 proposalTime = kandilli.getAuctionWinnerProposalTime(auctionId);
        vm.warp(proposalTime + fraudChallengePeriod + 1);

        vm.startPrank(utils.getNamedUser("bot"));
        for (uint256 i = 0; i < pwr.winnerBidIds.length; i++) {
            kandilli.claimWinningBid(auctionId, pwr.hash, pwr.winnerBidIds, i);
        }
        vm.stopPrank();
        bids = kandilli.getAuctionBids(auctionId, 0, 0);
        for (uint256 i = 0; i < bids.length; i++) {
            if (bids[i].timePassedFromStart != -1) {
                vm.prank(bids[i].bidder);
                kandilli.withdrawLostBid(auctionId, i, pwr.hash, pwr.winnerBidIds);
            }
        }

        uint256 totalPaidSnuffBounty = kandilli.getAuctionRetroSnuffBounty(auctionId);
        uint256 totalPaidProposalBounty = kandilli.getAuctionWinnersProposalBounty(auctionId);

        if (totalPaidSnuffBounty > 0) {
            vm.prank(utils.getNamedUser("snuffer"));
            kandilli.claimSnuffBounty(auctionId);
        }
        if (totalPaidProposalBounty > 0) {
            vm.prank(utils.getNamedUser("proposer"));
            kandilli.claimWinnersProposalBounty(auctionId);
        }
    }

    function _sendBids(
        uint256 auctionId,
        uint256 bidCountToSend,
        uint256 startTime,
        uint256 randE
    ) private {
        for (uint256 i = 0; i < bidCountToSend; i++) {
            uint256 rand = uint256(keccak256(abi.encodePacked(randE, i)));
            vm.warp(startTime + uint256(rand % auctionTotalDuration));
            address bidder = utils.getNamedUser(string(abi.encodePacked("bidder", i.toString())));
            vm.deal(bidder, 1 ether);
            vm.prank(bidder);
            vm.expectEmit(true, true, false, true);
            emit AuctionBid(bidder, auctionId, i, ((rand % 1000000) + 200000) * 100 gwei);
            kandilli.addBidToAuction{value: ((rand % 1000000) + 200000) * 100 gwei}(auctionId);
        }
    }

    function _snuffCandle(
        uint256 auctionId,
        uint256 vrf,
        uint256 startTime
    ) private {
        vm.warp(startTime + auctionTotalDuration + 1);
        address snuffer = utils.getNamedUser("snuffer");
        vm.startPrank(snuffer);

        vm.expectEmit(true, true, false, true);
        emit Approval(snuffer, address(kandilli), vrfFee);
        linkToken.approve(address(kandilli), vrfFee);

        vm.expectEmit(true, false, false, true);
        emit AuctionStarted(auctionId + 1, startTime + auctionTotalDuration + 1);
        vm.expectEmit(true, false, false, false);
        emit CandleSnuffed(snuffer, 1, bytes32(0));

        bytes32 requestId = kandilli.retroSnuffCandle(auctionId);
        vm.stopPrank();
        if (requestId != bytes32(0)) {
            vrfCoordinatorMock.callBackWithRandomness(requestId, vrf, address(kandilli));
        }
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
            if (startTime + uint256(uint32(result.bids[i].timePassedFromStart)) < result.snuffTime) {
                bidCount++;
            }
        }
        //Bid with index to sort with for same amount
        result.nBids = new IKandilli.KandilBidWithIndex[](bidCount);
        uint256 ni = 0;
        for (uint256 i = 0; i < result.bids.length; i++) {
            if (startTime + uint256(uint32(result.bids[i].timePassedFromStart)) < result.snuffTime) {
                result.nBids[ni++] = IKandilli.KandilBidWithIndex(
                    result.bids[i].bidder,
                    result.bids[i].timePassedFromStart,
                    result.bids[i].bidAmount,
                    uint32(i)
                );
            }
        }
        if (result.nBids.length > 1) {
            result.nBids = Helpers.sortBids(result.nBids);
        }

        result.numWinners = kandilli.getAuctionMaxWinnerCount(auctionId);
        result.vrfResult = kandilli.getAuctionVRF(auctionId);

        uint256 depositAmount = kandilli.getAuctionRequiredWinnersProposalDeposit(auctionId);

        if (result.numWinners > result.nBids.length) {
            result.numWinners = result.nBids.length;
        }

        result.winnerBidIds = new uint32[](result.numWinners);
        result.totalBidAmount = 0;
        for (uint256 i = 0; i < result.numWinners; i++) {
            result.winnerBidIds[i] = uint32(result.nBids[i].index);
            result.totalBidAmount += uint64(result.nBids[i].bidAmount);
        }

        result.hash = keccak256(abi.encodePacked(result.winnerBidIds, result.vrfResult));
        if (callPropose) {
            vm.deal(utils.getNamedUser("proposer"), depositAmount);
            vm.prank(utils.getNamedUser("proposer"));
            kandilli.proposeWinners{value: depositAmount}(auctionId, result.winnerBidIds, result.hash, result.totalBidAmount);
        }
    }
}

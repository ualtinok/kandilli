// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.0;

import {PRBTest} from "@prb/test/src/PRBTest.sol";
import {Utilities} from "../test/utils/Utilities.sol";
import {console2} from "forge-std/src/console2.sol";
import {StdCheats} from "forge-std/src/StdCheats.sol";
import {Vm} from "forge-std/src/Vm.sol";
import {Kandilli} from "../Kandilli.sol";
import {MockAuctionableToken} from "./mocks/MockAuctionableToken.sol";
import {WETH} from "./mocks/WETH.sol";
import {IKandilli} from "../interfaces/IKandilli.sol";
import {Helpers} from "../libraries/Helpers.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

    struct ProposeWinnersResult {
        bytes32 hash;
        uint24[] winnerBidIds;
        bytes winnerBidIdsBytes;
        IKandilli.KandilBidWithIndex[] nBids;
        IKandilli.KandilBid[] bids;
        uint256 entropyResult;
        uint256 numWinners;
        uint256 snuffTime;
        uint64 totalBidAmount;
    }

contract KandilliTest is PRBTest, StdCheats {
    using Strings for uint256;

    event AuctionStarted(uint256 indexed auctionId, uint256 minBidAmount, uint256 settingsId);
    event SettingsUpdated(IKandilli.KandilAuctionSettings settings, uint256 settingsId);
    event AuctionBid(address indexed sender, uint256 indexed auctionId, uint256 indexed bidId, uint256 value);
    event AuctionBidIncrease(address indexed sender, uint256 indexed auctionId, uint256 indexed bidId, uint256 value);
    event AuctionWinnersProposed(
        address indexed sender,
        uint256 indexed auctionId,
        bytes32 hash,
        uint256 winnerCount,
        uint256 snuffBounty,
        uint256 winnerProposalBounty
    );
    event CandleSnuffed(address indexed sender, uint256 indexed auctionId, uint256 entropyResult);
    event WinningBidClaimed(
        address indexed sender, uint256 indexed auctionId, uint256 indexed bidId, address claimedto, uint256 tokenId
    );
    event LostBidWithdrawn(address indexed sender, uint256 indexed auctionId, uint256 indexed bidId);
    event WinnersProposalBountyClaimed(address indexed sender, uint256 indexed auctionId, uint256 amount);
    event SnuffBountyClaimed(address indexed sender, uint256 indexed auctionId, uint256 amount);
    event ChallengeSucceded(address indexed sender, uint256 indexed auctionId, uint256 reason);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    Utilities internal utils;
    Kandilli internal kandilli;
    MockAuctionableToken internal mockAuctionableToken;
    WETH internal weth;
    address payable[] internal users;
    address payable internal alice;
    address payable internal bob;

    uint48 internal winnersProposalDeposit = (1 ether) / (1 gwei); // 1 ether
    uint32 internal auctionTotalDuration = 259200; // 3 days
    uint32 internal fraudChallengePeriod = 10800; // 3 hours
    uint32 internal snuffGas = 400_000; // 200k gas
    uint32 internal postWinnerGasCost = 500_000; // 200k gas
    // If you change this make sure there's less winners than bids that are before snuff time.
    // Otherwise some tests will fail.
    uint16 internal initMaxNumWinners = 32; // 32 users
    uint8 internal initMaxBountyMultiplier = 10;
    uint8 internal initSnuffPercentage = 30;

    bytes32 internal keyHash = 0x6c3699283bda56ad74f6b855546325b68d482e983852a7a82979cc4807b641f4;

    uint256 internal randomE = 18392480285055155400540772292264222449548204563388120189582018752977384988357;

    // This is to get a random number via FFI. Can comment out and enable ffi via (test --ffi or via toml)
    // Requires nodejs installed
    bool randomViaFFI = false;

    uint256 maxTestBidCount = 200;

    IKandilli.KandilAuctionSettings settings;

    function setUp() public {
        utils = new Utilities();
        if (randomViaFFI) {
            randomE = utils.getRandomNumber();
        }
        users = utils.createUsers(100);
        alice = users[0];
        bob = users[1];
        mockAuctionableToken = new MockAuctionableToken();
        weth = new WETH();
        settings = IKandilli.KandilAuctionSettings({
            winnersProposalDepositAmount: winnersProposalDeposit,
            fraudChallengePeriod: fraudChallengePeriod,
            snuffGas: snuffGas,
            winnersProposalGas: postWinnerGasCost,
            auctionTotalDuration: auctionTotalDuration,
            maxWinnersPerAuction: initMaxNumWinners,
            maxBountyMultiplier: initMaxBountyMultiplier,
            snuffPercentage: initSnuffPercentage
        });
        uint16[96] memory initialBidAmounts;
        for (uint256 i = 0; i < 96; i++) {
            initialBidAmounts[i] = 100;
        }
        vm.prank(utils.getNamedUser("deployer"));
        kandilli = new Kandilli(mockAuctionableToken, initialBidAmounts, address(weth));
    }

    function testInit() public {
        vm.expectRevert("Ownable: caller is not the owner");
        kandilli.init(settings);
        vm.startPrank(utils.getNamedUser("deployer"));
        kandilli.init(settings);
        vm.expectRevert(abi.encodeWithSignature("AlreadyInitialized()"));
        kandilli.init(settings);
    }

    function testBids() public {
        vm.prank(utils.getNamedUser("deployer"));
        kandilli.init(settings);
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
        vm.expectRevert(abi.encodeWithSignature("KandilStateDoesntMatch()"));
        kandilli.addBidToAuction{value: 1 ether}(99);

        // Fail if lower then gwei precision bid
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("BidWithPrecisionLowerThanGwei()"));
        kandilli.addBidToAuction{value: 1 wei}(auctionId);

        vm.prank(alice);
        vm.warp(startTime + auctionTotalDuration + 1);
        vm.expectRevert(abi.encodeWithSignature("KandilStateDoesntMatch()"));
        kandilli.addBidToAuction{value: 1 ether}(auctionId);
    }

    function testIncreaseBid() public {
        vm.prank(utils.getNamedUser("deployer"));
        kandilli.init(settings);
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
        assertEq(uint256(bids[bidId].bidAmount) * (1 gwei), 2 ether);
        vm.stopPrank();
        // Fail when try to increase someone else's bid
        vm.startPrank(bob);
        vm.expectRevert(abi.encodeWithSignature("CannotIncreaseBidForNonOwnedBid()"));
        kandilli.increaseAmountOfBid{value: 1 ether}(auctionId, bidId);
    }

    function testSnuffCandle(uint256 randomE, uint16 timePassed) public {
        /*        uint256 randomE = 65767386873957718740268074328995333784005072918202063793299981458799458871201;
        uint16 timePassed = 0;*/
        vm.prevrandao(bytes32(randomE));
        vm.startPrank(utils.getNamedUser("deployer"));
        kandilli.init(settings);
        vm.stopPrank();

        uint256 auctionId = 1;
        uint256 numBids = randomE % maxTestBidCount;
        uint256 startTime = kandilli.getAuctionStartTime(auctionId);
        uint256 maxNumWinners = kandilli.getAuctionMaxWinnerCount(auctionId);
        console2.log("maxNumWinners: ", maxNumWinners);
        console2.log("numBids: ", numBids);
        console2.log("bal: ", address(kandilli).balance);

        _sendBids(auctionId, numBids, startTime, randomE);
        console2.log("bal3: ", address(kandilli).balance);

        vm.expectRevert(abi.encodeWithSignature("KandilStateDoesntMatch()"));
        kandilli.snuffCandle(1);

        vm.expectRevert(abi.encodeWithSignature("KandilStateDoesntMatch()"));
        kandilli.snuffCandle(99);

        vm.warp(startTime + auctionTotalDuration + timePassed);

        if (numBids == 0) {
            vm.startPrank(alice);
            vm.expectEmit(true, false, false, true);
            emit CandleSnuffed(alice, auctionId, block.prevrandao);
            kandilli.snuffCandle(auctionId);
            IKandilli.KandilState state = kandilli.getAuctionState(auctionId);
            assertEq(uint256(state), uint256(IKandilli.KandilState.EndedWithoutBids));
            vm.stopPrank();
            return;
        }

        {
            vm.startPrank(alice);
            vm.expectEmit(true, false, false, false);
            emit CandleSnuffed(alice, auctionId, block.prevrandao);
            kandilli.snuffCandle(auctionId);
            vm.stopPrank();
        }

        {
            uint256 entropy = kandilli.getAuctionEntropy(auctionId);
            uint256 snuffTime = kandilli.getAuctionCandleSnuffedTime(auctionId);
            uint256 endTime = kandilli.getAuctionDefiniteEndTime(auctionId);
            uint256 snuffPercentage = kandilli.getAuctionSnuffPercentage(auctionId);
            uint256 snuffEarliestPossibleTime = endTime - (((endTime - startTime) * snuffPercentage) / 100);

            console2.log("entropy: ", entropy);
            assertGt(snuffTime, startTime);
            assertLt(snuffTime, endTime);
            assertGte(snuffTime, snuffEarliestPossibleTime);
        }

        // Fail when trying to candle that's already snuffed
        vm.expectRevert(abi.encodeWithSignature("KandilStateDoesntMatch()"));
        kandilli.snuffCandle(auctionId);

        vm.expectRevert(abi.encodeWithSignature("KandilStateDoesntMatch()"));
        kandilli.claimSnuffBounty(auctionId);

        uint256 currentSnuffBounty = kandilli.getAuctionSnuffBounty(auctionId);
        assertEq(currentSnuffBounty, 0);

        ProposeWinnersResult memory pwr = _proposeWinners(auctionId, startTime, true);
        console2.log("tot", pwr.totalBidAmount);
        console2.log("numWinner", pwr.numWinners);

        vm.startPrank(alice);

        vm.expectRevert(abi.encodeWithSignature("KandilStateDoesntMatch()"));
        kandilli.claimSnuffBounty(auctionId);

        uint256 proposalTime = kandilli.getAuctionWinnerProposalTime(auctionId);
        vm.warp(proposalTime + fraudChallengePeriod + 1);

        currentSnuffBounty = kandilli.getAuctionSnuffBounty(auctionId);

        vm.stopPrank();
        vm.expectRevert(abi.encodeWithSignature("CannotClaimSnuffBountyBeforeIfNotSnuffer()"));
        kandilli.claimSnuffBounty(auctionId);

        vm.startPrank(alice);
        if (currentSnuffBounty > 0) {
            uint256 beforeBalance = alice.balance;
            kandilli.claimSnuffBounty(auctionId);
            uint256 afterBalance = alice.balance;
            assertEq(afterBalance - beforeBalance, currentSnuffBounty);
        }
    }

    function testProposeWinners(uint256 randomE) public {
        //uint256 randomE = 511509300450453690715166972283816001;
        vm.prank(utils.getNamedUser("deployer"));
        kandilli.init(settings);

        uint256 auctionId = 1;
        uint256 depositAmount = kandilli.getAuctionRequiredWinnersProposalDeposit(auctionId);
        uint256 startTime = kandilli.getAuctionStartTime(auctionId);
        uint256 numBids = randomE % maxTestBidCount;
        // Fail when posting winners before candle snuffed
        {
            uint24[] memory dummyWinnerIds = new uint24[](3);
            bytes32 dummyHash = keccak256(abi.encodePacked("x"));

            dummyWinnerIds[0] = 3;
            dummyWinnerIds[1] = 3;
            dummyWinnerIds[2] = 3;
            vm.expectRevert(abi.encodeWithSignature("KandilStateDoesntMatch()"));
            kandilli.proposeWinners{value: depositAmount}(auctionId, uint24ArrToBytes(dummyWinnerIds), dummyHash, 0);
        }

        _sendBids(auctionId, numBids, startTime, randomE);
        _snuffCandle(auctionId, randomE, startTime);

        IKandilli.KandilState state = kandilli.getAuctionState(auctionId);

        // No bids
        if (state == IKandilli.KandilState.EndedWithoutBids) {
            uint24[] memory dummyWinnerIds = new uint24[](3);
            bytes32 dummyHash = keccak256(abi.encodePacked("x"));

            dummyWinnerIds[0] = 3;
            dummyWinnerIds[1] = 3;
            dummyWinnerIds[2] = 3;
            vm.expectRevert(abi.encodeWithSignature("KandilStateDoesntMatch()"));
            kandilli.proposeWinners{value: depositAmount}(auctionId, uint24ArrToBytes(dummyWinnerIds), dummyHash, 0);

            return;
        }
        assertEq(uint256(state), uint256(IKandilli.KandilState.WaitingWinnersProposal));
        ProposeWinnersResult memory pwr = _proposeWinners(auctionId, startTime, false);
        // Fail when posting winners with wrong hash
        vm.expectRevert(abi.encodeWithSignature("IncorrectHashForWinnerBids()"));
        kandilli.proposeWinners{value: depositAmount}(
            auctionId, pwr.winnerBidIdsBytes, keccak256(abi.encodePacked("x")), pwr.totalBidAmount
        );

        bytes32 hash = keccak256(abi.encodePacked(pwr.winnerBidIdsBytes));

        // Fail when posting winners with wrong deposit amount
        vm.expectRevert(abi.encodeWithSignature("DepositAmountForWinnersProposalNotMet()"));
        kandilli.proposeWinners{value: 1 wei}(auctionId, pwr.winnerBidIdsBytes, pwr.hash, pwr.totalBidAmount);

        // Succeed to post winners and check balance
        {
            uint256 proposalBounty = kandilli.getAuctionPotentialWinnersProposalBounty(auctionId);
            uint256 snuffBounty = kandilli.getAuctionPotentialSnuffBounty(auctionId);
            uint256 minB = kandilli.getAuctionMinimumBidAmount(auctionId);

            // Check actual bounties based on winner proposal
            uint256 totalMinBids = pwr.numWinners * minB;
            uint256 totalBidAmount = pwr.totalBidAmount * (1 gwei);
            if (totalBidAmount > totalMinBids) {
                uint256 extraFunds = totalBidAmount - totalMinBids;
                proposalBounty = proposalBounty < extraFunds ? proposalBounty : extraFunds;
            } else {
                // No bounty for proposing winners as we haven't got extra from bids. We prioritize auctionable settling.
                proposalBounty = 0;
            }
            // Here we check how much extra we have to give for bounty. We also need to substract winners proposal bounty.
            if (totalBidAmount > totalMinBids + proposalBounty) {
                uint256 extraFunds = totalBidAmount - totalMinBids - proposalBounty;
                snuffBounty = snuffBounty < extraFunds ? snuffBounty : extraFunds;
            } else {
                snuffBounty = 0;
            }

            uint256 aliceBalanceBefore = alice.balance;
            vm.prank(alice);
            vm.expectEmit(true, false, false, true);
            emit AuctionWinnersProposed(alice, auctionId, pwr.hash, pwr.numWinners, snuffBounty, proposalBounty);
            kandilli.proposeWinners{value: depositAmount}(
                auctionId, pwr.winnerBidIdsBytes, pwr.hash, pwr.totalBidAmount
            );
            uint256 aliceBalanceAfter = alice.balance;
            assertEq(aliceBalanceBefore - aliceBalanceAfter, depositAmount);
        }

        // Fail when posting winners a second time
        {
            vm.expectRevert(abi.encodeWithSignature("KandilStateDoesntMatch()"));
            kandilli.proposeWinners{value: depositAmount}(
                auctionId, pwr.winnerBidIdsBytes, pwr.hash, pwr.totalBidAmount
            );
        }
        //uint256 totalPaidProposalBounty = kandilli.getAuctionWinnersProposalBounty(auctionId);
    }

    function testClaimToken(uint256 randomE) public {
        vm.prank(utils.getNamedUser("deployer"));
        kandilli.init(settings);

        //uint256 randomE = 513364110310922539964742487704664574486530143139934386000;
        uint256 auctionId = 1;
        uint256 startTime = kandilli.getAuctionStartTime(auctionId);
        uint256 numBids = (randomE % maxTestBidCount) + 1; // Need at least 1 bid to claim token.

        uint24[] memory dummyWinnerIds = new uint24[](3);
        _sendBids(auctionId, numBids, startTime, randomE);
        _snuffCandle(auctionId, randomE, startTime);

        vm.expectRevert(abi.encodeWithSignature("KandilStateDoesntMatch()"));
        kandilli.claimWinningBid(auctionId, bytes32(0), uint24ArrToBytes(dummyWinnerIds), 0);

        ProposeWinnersResult memory pwr = _proposeWinners(auctionId, startTime, true);

        if (pwr.winnerBidIds.length == 0) {
            // TODO: vm.assume
            return;
        }
        vm.expectRevert(abi.encodeWithSignature("KandilStateDoesntMatch()"));
        kandilli.claimWinningBid(auctionId, pwr.hash, pwr.winnerBidIdsBytes, 0);

        uint256 proposalTime = kandilli.getAuctionWinnerProposalTime(auctionId);
        vm.warp(proposalTime + fraudChallengePeriod + 1);

        vm.expectRevert(abi.encodeWithSignature("BidIdDoesntExist()"));
        kandilli.claimWinningBid(auctionId, pwr.hash, pwr.winnerBidIdsBytes, pwr.winnerBidIds.length);

        bytes32 dummyHash = keccak256(abi.encodePacked(uint24ArrToBytes(dummyWinnerIds)));
        dummyWinnerIds[0] = 0;
        dummyWinnerIds[1] = 4;
        dummyWinnerIds[2] = 4;

        vm.expectRevert(abi.encodeWithSignature("WinnerProposalDataDoesntHaveCorrectHash()"));
        kandilli.claimWinningBid(auctionId, dummyHash, uint24ArrToBytes(dummyWinnerIds), 0);
        dummyHash = keccak256(abi.encodePacked(uint24ArrToBytes(dummyWinnerIds)));
        vm.expectRevert(abi.encodeWithSignature("WinnerProposalHashDoesntMatchPostedHash()"));
        kandilli.claimWinningBid(auctionId, dummyHash, uint24ArrToBytes(dummyWinnerIds), 0);

        uint256 toClaimId = randomE % pwr.winnerBidIds.length;

        address payable someOtherUser = utils.getNamedUser("someOtherUser");
        uint256 someOtherUserBeforeBalance = someOtherUser.balance;
        vm.prank(someOtherUser);
        vm.expectEmit(true, false, false, true);
        emit WinningBidClaimed(
            someOtherUser, 1, pwr.winnerBidIds[toClaimId], pwr.bids[pwr.winnerBidIds[toClaimId]].bidder, 0
        );
        kandilli.claimWinningBid(auctionId, pwr.hash, pwr.winnerBidIdsBytes, toClaimId);
        uint256 claimBounty = kandilli.getAuctionMinimumBidAmount(auctionId);

        // Check if someOtherUser received right bounty.
        assertEq(
            claimBounty, someOtherUser.balance - someOtherUserBeforeBalance, "Received bounty for snuff is incorrect"
        );

        // Check if bidder received token.
        assertEq(
            mockAuctionableToken.balanceOf(pwr.bids[pwr.winnerBidIds[toClaimId]].bidder),
            1,
            "Bidder did not receive token"
        );

        // Check that someOtherUser did not receive any tokens.
        assertEq(
            mockAuctionableToken.balanceOf(someOtherUser), 0, "SomeOtherUser received tokens, when she shouldn't have"
        );

        // Fail to claim tokens that are already claimed.
        vm.expectRevert(abi.encodeWithSignature("BidAlreadyClaimed()"));
        kandilli.claimWinningBid(auctionId, pwr.hash, pwr.winnerBidIdsBytes, toClaimId);
    }

    function testWithdrawBid(uint256 randomE) public {
        vm.prank(utils.getNamedUser("deployer"));
        kandilli.init(settings);

        uint256 auctionId = 1;
        uint256 startTime = kandilli.getAuctionStartTime(auctionId);
        uint256 numBids = (randomE % maxTestBidCount) + 1;

        _sendBids(auctionId, numBids, startTime, randomE);
        _snuffCandle(auctionId, randomE, startTime);

        ProposeWinnersResult memory pwr = _proposeWinners(auctionId, startTime, true);

        vm.assume(pwr.nBids.length != pwr.numWinners);
        uint256 proposalTime = kandilli.getAuctionWinnerProposalTime(auctionId);
        vm.warp(proposalTime + fraudChallengePeriod + 1);

        uint24[] memory dummyWinnerIds = new uint24[](3);
        bytes32 dummyHash = keccak256(abi.encodePacked(uint24ArrToBytes(dummyWinnerIds)));
        dummyWinnerIds[0] = 0;
        dummyWinnerIds[1] = 4;
        dummyWinnerIds[2] = 1;
        vm.expectRevert(abi.encodeWithSignature("WinnerProposalDataDoesntHaveCorrectHash()"));
        kandilli.withdrawLostBid(auctionId, dummyWinnerIds[0], dummyHash, uint24ArrToBytes(dummyWinnerIds));

        dummyHash = keccak256(abi.encodePacked(uint24ArrToBytes(dummyWinnerIds)));
        vm.expectRevert(abi.encodeWithSignature("WinnerProposalHashDoesntMatchPostedHash()"));
        kandilli.withdrawLostBid(auctionId, dummyWinnerIds[0], dummyHash, uint24ArrToBytes(dummyWinnerIds));

        vm.expectRevert(abi.encodeWithSignature("CannotWithdrawLostBidIfIncludedInWinnersProposal()"));
        kandilli.withdrawLostBid(auctionId, pwr.winnerBidIds[0], pwr.hash, pwr.winnerBidIdsBytes);

        vm.expectRevert(abi.encodeWithSignature("CannotWithdrawBidIfNotSender()"));
        kandilli.withdrawLostBid(auctionId, pwr.nBids[pwr.numWinners].index, pwr.hash, pwr.winnerBidIdsBytes);

        uint256 beforeBalance = pwr.nBids[pwr.numWinners].bidder.balance;

        vm.expectEmit(true, true, false, true);
        emit LostBidWithdrawn(pwr.nBids[pwr.numWinners].bidder, auctionId, pwr.nBids[pwr.numWinners].index);
        vm.prank(pwr.nBids[pwr.numWinners].bidder);
        kandilli.withdrawLostBid(auctionId, pwr.nBids[pwr.numWinners].index, pwr.hash, pwr.winnerBidIdsBytes);
        uint256 afterBalance = pwr.nBids[pwr.numWinners].bidder.balance;

        assertEq(
            afterBalance - beforeBalance,
            uint256(pwr.nBids[pwr.numWinners].bidAmount) * (1 gwei),
            "Didn't withdraw correct amount"
        );

        vm.expectRevert(abi.encodeWithSignature("CannotWithdrawAlreadyWithdrawnBid()"));
        kandilli.withdrawLostBid(auctionId, pwr.nBids[pwr.numWinners].index, pwr.hash, pwr.winnerBidIdsBytes);
    }

    function testChallengeWinnersProposals(uint256 randomE) public {
        vm.prank(utils.getNamedUser("deployer"));
        kandilli.init(settings);

        //uint256 randomE = 3;

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
            uint24[] memory dummyWinnerIds = new uint24[](pwr.bids.length + 1);
            bytes32 dummyHash = keccak256(abi.encodePacked(uint24ArrToBytes(dummyWinnerIds)));
            kandilli.proposeWinners{value: depositAmount}(
                auctionId, uint24ArrToBytes(dummyWinnerIds), dummyHash, pwr.totalBidAmount
            );
            address challenger = utils.getNamedUser("challenger");

            vm.expectEmit(true, false, false, true);
            emit ChallengeSucceded(challenger, auctionId, 1);
            vm.prank(challenger);
            uint256 chalBalBefore = challenger.balance;
            kandilli.challengeProposedWinners(auctionId, uint24ArrToBytes(dummyWinnerIds), dummyHash, 1);
            uint256 chalBalAfter = challenger.balance;
            assertEq(chalBalAfter, chalBalBefore + depositAmount, "Challenger didn't receive enough bounty");
        }

        // Send duplicate winner bids
        if (pwr.numWinners > 2) {
            uint24[] memory dummyWinnerIds = new uint24[](3);
            dummyWinnerIds[0] = pwr.winnerBidIds[0];
            dummyWinnerIds[1] = pwr.winnerBidIds[1];
            dummyWinnerIds[2] = pwr.winnerBidIds[0];
            bytes32 dummyHash = keccak256(abi.encodePacked(uint24ArrToBytes(dummyWinnerIds)));
            kandilli.proposeWinners{value: depositAmount}(
                auctionId, uint24ArrToBytes(dummyWinnerIds), dummyHash, pwr.totalBidAmount
            );
            address challenger = utils.getNamedUser("challenger");

            vm.expectEmit(true, false, false, true);
            emit ChallengeSucceded(challenger, auctionId, 2);
            vm.prank(challenger);
            uint256 chalBalBefore = challenger.balance;
            kandilli.challengeProposedWinners(
                auctionId, uint24ArrToBytes(dummyWinnerIds), dummyHash, pwr.winnerBidIds[2]
            );
            uint256 chalBalAfter = challenger.balance;
            assertEq(chalBalAfter, chalBalBefore + depositAmount, "Challenger didn't receive enough bounty");
        }

        // Propose bigger winner index than total bid count.
        if (pwr.numWinners > 0) {
            uint24[] memory dummyWinnerIds = new uint24[](pwr.numWinners);
            for (uint256 i = 0; i < pwr.numWinners; i++) {
                dummyWinnerIds[i] = pwr.winnerBidIds[i];
            }
            dummyWinnerIds[0] = uint16(pwr.bids.length);
            bytes32 dummyHash = keccak256(abi.encodePacked(uint24ArrToBytes(dummyWinnerIds)));
            kandilli.proposeWinners{value: depositAmount}(
                auctionId, uint24ArrToBytes(dummyWinnerIds), dummyHash, pwr.totalBidAmount
            );
            address challenger = utils.getNamedUser("challenger");

            vm.expectEmit(true, false, false, true);
            emit ChallengeSucceded(challenger, auctionId, 3);
            vm.prank(challenger);
            uint256 chalBalBefore = challenger.balance;
            kandilli.challengeProposedWinners(auctionId, uint24ArrToBytes(dummyWinnerIds), dummyHash, type(uint24).max);
            uint256 chalBalAfter = challenger.balance;
            assertEq(chalBalAfter, chalBalBefore + depositAmount, "Challenger didn't receive enough bounty");
        }

        // Send bid which is after snuff time
        {
            uint24 bidAfterSnuff = type(uint24).max;
            for (uint256 i = 0; i < pwr.bids.length; i++) {
                if (uint256(pwr.bids[i].timestamp) >= pwr.snuffTime) {
                    bidAfterSnuff = uint16(i);
                }
            }
            if (bidAfterSnuff == type(uint24).max) {
                return;
            }
            uint24[] memory dummyWinnerIds = new uint24[](1);
            dummyWinnerIds[0] = bidAfterSnuff;
            bytes32 dummyHash = keccak256(abi.encodePacked(uint24ArrToBytes(dummyWinnerIds)));
            kandilli.proposeWinners{value: depositAmount}(
                auctionId, uint24ArrToBytes(dummyWinnerIds), dummyHash, pwr.totalBidAmount
            );
            address challenger = utils.getNamedUser("challenger");

            vm.expectEmit(true, false, false, true);
            emit ChallengeSucceded(challenger, auctionId, 4);
            vm.prank(challenger);
            uint256 chalBalBefore = challenger.balance;
            kandilli.challengeProposedWinners(auctionId, uint24ArrToBytes(dummyWinnerIds), dummyHash, type(uint24).max);
            uint256 chalBalAfter = challenger.balance;
            assertEq(chalBalAfter, chalBalBefore + depositAmount, "Challenger didn't receive enough bounty");
        }

        // Send wrong total amount
        if (pwr.totalBidAmount > 0) {
            kandilli.proposeWinners{value: depositAmount}(
                auctionId, pwr.winnerBidIdsBytes, pwr.hash, pwr.totalBidAmount - 1
            );
            address challenger = utils.getNamedUser("challenger");
            vm.expectEmit(true, false, false, true);
            emit ChallengeSucceded(challenger, auctionId, 6);
            vm.prank(challenger);
            kandilli.challengeProposedWinners(auctionId, pwr.winnerBidIdsBytes, pwr.hash, type(uint24).max);
        }

        // Send bad list #1:  last 2 items swapped
        if (pwr.numWinners > 1) {
            uint24[] memory dummyWinnerIds = new uint24[](pwr.numWinners);
            for (uint256 i = 0; i < pwr.numWinners; i++) {
                dummyWinnerIds[i] = uint16(pwr.nBids[i].index);
            }

            (dummyWinnerIds[pwr.numWinners - 1], dummyWinnerIds[pwr.numWinners - 2]) =
            (dummyWinnerIds[pwr.numWinners - 2], dummyWinnerIds[pwr.numWinners - 1]);

            bytes32 dummyHash = keccak256(abi.encodePacked(uint24ArrToBytes(dummyWinnerIds)));
            kandilli.proposeWinners{value: depositAmount}(
                auctionId, uint24ArrToBytes(dummyWinnerIds), dummyHash, pwr.totalBidAmount
            );
            address challenger = utils.getNamedUser("challenger");

            vm.expectEmit(true, false, false, true);
            emit ChallengeSucceded(challenger, auctionId, 7);
            vm.prank(challenger);
            uint256 chalBalBefore = challenger.balance;
            kandilli.challengeProposedWinners(auctionId, uint24ArrToBytes(dummyWinnerIds), dummyHash, type(uint24).max);
            uint256 chalBalAfter = challenger.balance;
            assertEq(chalBalAfter, chalBalBefore + depositAmount, "Challenger didn't receive enough bounty");
        }

        // Send bad list #2: Swap first loser with last winner.
        if (pwr.numWinners > numBids) {
            uint24[] memory dummyWinnerIds = new uint24[](pwr.numWinners);
            for (uint256 i = 0; i < pwr.numWinners - 1; i++) {
                dummyWinnerIds[i] = uint16(pwr.nBids[i].index);
            }
            dummyWinnerIds[pwr.numWinners - 1] = uint16(pwr.nBids[pwr.numWinners].index);
            bytes32 dummyHash = keccak256(abi.encodePacked(uint24ArrToBytes(dummyWinnerIds)));
            kandilli.proposeWinners{value: depositAmount}(
                auctionId, uint24ArrToBytes(dummyWinnerIds), dummyHash, pwr.totalBidAmount
            );
            address challenger = utils.getNamedUser("challenger");

            vm.expectEmit(true, false, false, true);
            emit ChallengeSucceded(challenger, auctionId, 7);
            vm.prank(challenger);
            uint256 chalBalBefore = challenger.balance;
            kandilli.challengeProposedWinners(
                auctionId, uint24ArrToBytes(dummyWinnerIds), dummyHash, uint16(pwr.nBids[pwr.numWinners - 1].index)
            );
            uint256 chalBalAfter = challenger.balance;
            assertEq(chalBalAfter, chalBalBefore + depositAmount, "Challenger didn't receive enough bounty");
        }

        // Try to repropose winners after successful fraud proof.
        _proposeWinners(auctionId, startTime, true);

        vm.expectRevert(abi.encodeWithSignature("ChallengeFailedWinnerProposalIsCorrect()"));
        kandilli.challengeProposedWinners(auctionId, pwr.winnerBidIdsBytes, pwr.hash, type(uint24).max);
    }

    function testChallengeWinnersProposalFailures(uint256 randomE) public {
        vm.prank(utils.getNamedUser("deployer"));
        kandilli.init(settings);
        //uint256 randomE = 4499550098297379889107541569912050205441959294117414913041628694394132133202;
        uint256 auctionId = 1;
        uint256 startTime = kandilli.getAuctionStartTime(auctionId);
        uint256 numBids = randomE % maxTestBidCount;
        _sendBids(auctionId, numBids, startTime, randomE);
        _snuffCandle(auctionId, randomE, startTime);

        // Try to challenge when winners not yet posted
        {
            uint24[] memory dummyWinnerIds = new uint24[](3);
            dummyWinnerIds[0] = 3;
            dummyWinnerIds[1] = 3;
            dummyWinnerIds[2] = 3;
            vm.expectRevert(abi.encodeWithSignature("KandilStateDoesntMatch()"));
            kandilli.challengeProposedWinners(
                auctionId, uint24ArrToBytes(dummyWinnerIds), keccak256(abi.encodePacked("x")), 0
            );
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
            kandilli.challengeProposedWinners(auctionId, pwr.winnerBidIdsBytes, whash, 0);
        }

        {
            uint24[] memory dummyWinnerIds = new uint24[](3);
            dummyWinnerIds[0] = 3;
            dummyWinnerIds[1] = 3;
            dummyWinnerIds[2] = 3;
            bytes32 dummyHash = keccak256(abi.encodePacked(uint24ArrToBytes(dummyWinnerIds)));
            vm.expectRevert(abi.encodeWithSignature("WinnerProposalHashDoesntMatchPostedHash()"));
            kandilli.challengeProposedWinners(auctionId, uint24ArrToBytes(dummyWinnerIds), dummyHash, 0);
        }

        vm.prank(utils.getNamedUser("proposer"));
        vm.expectRevert(abi.encodeWithSignature("CannotChallengeSelfProposal()"));
        kandilli.challengeProposedWinners(auctionId, pwr.winnerBidIdsBytes, pwr.hash, 0);

        if (pwr.numWinners == 0) {
            // TODO: vm.assume
            return;
        }

        vm.startPrank(utils.getNamedUser("challenger"));
        vm.expectRevert(abi.encodeWithSignature("ChallengeFailedBidIdToIncludeAlreadyInWinnerList()"));
        kandilli.challengeProposedWinners(auctionId, pwr.winnerBidIdsBytes, pwr.hash, pwr.winnerBidIds[0]);

        vm.expectRevert(abi.encodeWithSignature("ChallengeFailedBidIdToIncludeIsNotInBidList()"));
        kandilli.challengeProposedWinners(auctionId, pwr.winnerBidIdsBytes, pwr.hash, uint16(pwr.bids.length));

        vm.expectRevert(abi.encodeWithSignature("ChallengeFailedWinnerProposalIsCorrect()"));
        kandilli.challengeProposedWinners(auctionId, pwr.winnerBidIdsBytes, pwr.hash, type(uint24).max);

        // Fail to challenge after challenge period
        uint256 proposalTime = kandilli.getAuctionWinnerProposalTime(auctionId);
        vm.warp(proposalTime + fraudChallengePeriod + 1);
        vm.expectRevert(abi.encodeWithSignature("KandilStateDoesntMatch()"));
        kandilli.challengeProposedWinners(auctionId, pwr.winnerBidIdsBytes, pwr.hash, 0);
        vm.stopPrank();
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
        vm.prank(utils.getNamedUser("deployer"));
        kandilli.init(settings);

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
                assertEq(bids[i].timestamp, bids1[i].timestamp);
                assertEq(bids[i].bidAmount, bids1[i].bidAmount);
            } else {
                assertEq(bids[i].bidder, bids2[i - 50].bidder);
                assertEq(bids[i].timestamp, bids2[i - 50].timestamp);
                assertEq(bids[i].bidAmount, bids2[i - 50].bidAmount);
            }
        }
    }

    function testTransferFunds(uint256 randomE) public {
        vm.prank(utils.getNamedUser("deployer"));
        kandilli.init(settings);

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
        vm.expectRevert(abi.encodeWithSignature("KandilStateDoesntMatch()"));
        kandilli.transferAuctionFundsToOwner(auctionId);
        ProposeWinnersResult memory pwr = _proposeWinners(auctionId, startTime, true);

        vm.expectRevert(abi.encodeWithSignature("KandilStateDoesntMatch()"));
        kandilli.transferAuctionFundsToOwner(auctionId);

        uint256 proposalTime = kandilli.getAuctionWinnerProposalTime(auctionId);
        vm.warp(proposalTime + fraudChallengePeriod + 1);

        if (pwr.numWinners == 0) {
            //TODO: vm.assume
            return;
        }

        uint256 bidTotal = 0;
        vm.startPrank(utils.getNamedUser("bot"));
        for (uint256 i = 0; i < pwr.winnerBidIds.length; i++) {
            bidTotal += uint256(pwr.bids[pwr.winnerBidIds[i]].bidAmount) * (1 gwei);
            kandilli.claimWinningBid(auctionId, pwr.hash, pwr.winnerBidIdsBytes, i);
        }
        vm.stopPrank();
        IKandilli.KandilBid[] memory bids = kandilli.getAuctionBids(auctionId, 0, 0);
        for (uint256 i = 0; i < bids.length; i++) {
            if (!bids[i].isProcessed) {
                vm.prank(bids[i].bidder);
                kandilli.withdrawLostBid(auctionId, i, pwr.hash, pwr.winnerBidIdsBytes);
            }
        }

        uint256 totalPaidSnuffBounty = kandilli.getAuctionSnuffBounty(auctionId);
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
                kandilli.transferAuctionFundsToOwner(auctionId);
                uint256 ownerBalanceAfter = utils.getNamedUser("deployer").balance;

                assertEq(
                    bidTotal - totalPaidClaimBounty - totalPaidSnuffBounty - totalPaidProposalBounty,
                    ownerBalanceAfter - ownerBalanceBefore
                );
                assertEq(address(kandilli).balance, 0);

                vm.expectRevert(abi.encodeWithSignature("FundsAlreadyTransferred()"));
                kandilli.transferAuctionFundsToOwner(auctionId);
            } else {
                assertEq(address(kandilli).balance, 0);
                vm.expectRevert(abi.encodeWithSignature("EthTransferFailedDestOrAmountZero()"));
                kandilli.transferAuctionFundsToOwner(auctionId);
            }
        }
    }

    function testFullAuction() public {
        vm.prank(utils.getNamedUser("deployer"));
        kandilli.init(settings);

        uint256 auctionId = 1;
        uint256 startTime = kandilli.getAuctionStartTime(auctionId);
        uint256 numBids = 100;

        _sendBids(auctionId, numBids, startTime, randomE);
        IKandilli.KandilBid[] memory bids = kandilli.getAuctionBids(auctionId, 0, 0);

        for (uint256 i = 0; i < bids.length; i++) {
            vm.prank(bids[i].bidder);
            kandilli.increaseAmountOfBid{value: (1 gwei)}(auctionId, i);
        }
        _snuffCandle(auctionId, randomE, startTime);

        ProposeWinnersResult memory pwr = _proposeWinners(auctionId, startTime, true);

        vm.expectRevert(abi.encodeWithSignature("ChallengeFailedWinnerProposalIsCorrect()"));
        kandilli.challengeProposedWinners(auctionId, pwr.winnerBidIdsBytes, pwr.hash, type(uint24).max);

        uint256 proposalTime = kandilli.getAuctionWinnerProposalTime(auctionId);
        vm.warp(proposalTime + fraudChallengePeriod + 1);

        vm.startPrank(utils.getNamedUser("bot"));
        for (uint256 i = 0; i < pwr.winnerBidIds.length; i++) {
            kandilli.claimWinningBid(auctionId, pwr.hash, pwr.winnerBidIdsBytes, i);
        }
        vm.stopPrank();
        bids = kandilli.getAuctionBids(auctionId, 0, 0);
        for (uint256 i = 0; i < bids.length; i++) {
            if (!bids[i].isProcessed) {
                vm.prank(bids[i].bidder);
                if (i % 2 == 0) {
                    kandilli.withdrawLostBidAfterAllWinnersClaimed(auctionId, i);
                } else {
                    kandilli.withdrawLostBid(auctionId, i, pwr.hash, pwr.winnerBidIdsBytes);
                }
            }
        }

        uint256 totalPaidSnuffBounty = kandilli.getAuctionSnuffBounty(auctionId);
        uint256 totalPaidProposalBounty = kandilli.getAuctionWinnersProposalBounty(auctionId);

        if (totalPaidSnuffBounty > 0) {
            vm.prank(utils.getNamedUser("snuffer"));
            kandilli.claimSnuffBounty(auctionId);
        }
        if (totalPaidProposalBounty > 0) {
            vm.prank(utils.getNamedUser("proposer"));
            kandilli.claimWinnersProposalBounty(auctionId);
        }
        kandilli.transferAuctionFundsToOwner(auctionId);
    }

    function testPack() public {
        bytes memory arrMke =
                    hex"0f1103010d230023102313230f1103010d230023102313230f1103010d230023102313230f1103010d230023102313230f1103010d230023102313230f1103010d230023102313230f1103010d230023102313230f1103010d230023102313230f1103010d230023102313230f1103010d230023102313230f1103010d230023102313230f1103010d230023102313230f1103010d230023102313230f1103010d230023102313230f1103010d230023102313230f1103010d230023102313230f1103010d230023102313230f1103010d230023102313230f1103010d230023102313230f1103010d230023102313230f1103010d230023102313230f1103010d230023102313230f1103010d230023102313230f1103010d230023102313230f1103010d230023102313230f1103010d230023102313230f1103010d230023102313230f1103010d230023102313230f1103010d230023102313230f1103010d230023102313230f1103010d230023102313230f1103010d230023102313230f1103010d230023102313230f1103010d230023102313230f1103010d230023102313230f1103010d230023102313230f1103010d230023102313230f1103010d230023102313230f1103010d230023102313230f1103010d230023102313230f1103010d230023102313230f1103010d230023102313230f1103010d230023102313230f1103010d230023102313230f1103010d230023102313230f1103010d230023102313230f1103010d230023102313230f1103010d230023102313230f1103010d230023102313230f1103010d230023102313230f1103010d230023102313230f1103010d230023102313230f1103010d230023102313230f1103010d23002310231323";
        uint24[] memory x = bytesToUInt24Arr(arrMke);
        bytes memory y = uint24ArrToBytes(x);
        uint24[] memory c = bytesToUInt24Arr(y);
        assertEq(keccak256(abi.encode(x)), keccak256(abi.encode(c)));
        assertEq(keccak256(abi.encode(arrMke)), keccak256(abi.encode(y)));
    }

    function bytesToUInt24Arr(bytes memory _bytes) internal pure returns (uint24[] memory tempUint) {
        assembly {
            let length := div(mload(_bytes), 3) // get size of _bytes and divide by 3 to get uint24 arr size.
            tempUint := mload(0x40)
            mstore(add(tempUint, 0x00), length)
            let i := 0
            for {} lt(i, length) {i := add(i, 1)} {
                mstore(add(tempUint, add(mul(i, 0x20), 0x20)), mload(add(add(_bytes, 0x3), mul(i, 3))))
            }
            mstore(0x40, add(tempUint, add(mul(i, 0x20), 0x20)))
        }
    }

    function uint24ArrToBytes(uint24[] memory _uints) internal pure returns (bytes memory tempBytes) {
        uint256 length = _uints.length * 3;
        assembly {
            tempBytes := mload(0x40)
            mstore(tempBytes, length)
            let i := 0
            for {} lt(i, length) {i := add(i, 1)} {
                mstore(add(tempBytes, add(mul(3, i), 0x20)), shl(232, mload(add(_uints, add(mul(i, 0x20), 0x20)))))
            }
            mstore(0x40, add(tempBytes, add(0x40, mul(0x20, div(length, 0x20)))))
        }
    }

    function _sendBids(uint256 auctionId, uint256 bidCountToSend, uint256 startTime, uint256 randE) private {
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

    function _snuffCandle(uint256 auctionId, uint256 vrf, uint256 startTime) private {
        vm.warp(startTime + auctionTotalDuration + 1);
        address snuffer = utils.getNamedUser("snuffer");
        vm.startPrank(snuffer);

        /*        vm.expectEmit(true, true, false, true);
        emit Approval(snuffer, address(kandilli), vrfFee);
        linkToken.approve(address(kandilli), vrfFee);*/

        vm.expectEmit(true, false, false, false);
        emit AuctionStarted(auctionId + 1, 0, 0);
        vm.expectEmit(true, false, false, false);
        emit CandleSnuffed(snuffer, 1, block.prevrandao);

        kandilli.snuffCandle(auctionId);
        vm.stopPrank();
    }

    function _proposeWinners(uint256 auctionId, uint256 startTime, bool callPropose)
    private
    returns (ProposeWinnersResult memory result)
    {
        result.bids = kandilli.getAuctionBids(auctionId, 0, 0);
        result.snuffTime = kandilli.getAuctionCandleSnuffedTime(auctionId);
        uint256 bidCount = 0;

        // Count bids sent before snuff time.
        for (uint256 i = 0; i < result.bids.length; i++) {
            if (uint256(result.bids[i].timestamp) < result.snuffTime) {
                bidCount++;
            }
        }
        //Bid with index to sort with for same amount
        result.nBids = new IKandilli.KandilBidWithIndex[](bidCount);
        uint256 ni = 0;
        for (uint256 i = 0; i < result.bids.length; i++) {
            if (uint256(result.bids[i].timestamp) < result.snuffTime) {
                result.nBids[ni++] = IKandilli.KandilBidWithIndex({
                    bidder: result.bids[i].bidder,
                    timestamp: result.bids[i].timestamp,
                    bidAmount: result.bids[i].bidAmount,
                    isProcessed: result.bids[i].isProcessed,
                    index: uint24(i)
                });
            }
        }
        if (result.nBids.length > 1) {
            result.nBids = Helpers.sortBids(result.nBids);
        }

        result.numWinners = kandilli.getAuctionMaxWinnerCount(auctionId);
        result.entropyResult = kandilli.getAuctionEntropy(auctionId);

        uint256 depositAmount = kandilli.getAuctionRequiredWinnersProposalDeposit(auctionId);

        if (result.numWinners > result.nBids.length) {
            result.numWinners = result.nBids.length;
        }

        result.winnerBidIds = new uint24[](result.numWinners);
        result.totalBidAmount = 0;
        for (uint256 i = 0; i < result.numWinners; i++) {
            result.winnerBidIds[i] = uint24(result.nBids[i].index);
            result.totalBidAmount += uint64(result.nBids[i].bidAmount);
        }
        result.winnerBidIdsBytes = uint24ArrToBytes(result.winnerBidIds);
        result.hash = keccak256(abi.encodePacked(result.winnerBidIdsBytes));
        if (callPropose) {
            vm.deal(utils.getNamedUser("proposer"), depositAmount);
            vm.prank(utils.getNamedUser("proposer"));
            kandilli.proposeWinners{value: depositAmount}(
                auctionId, result.winnerBidIdsBytes, result.hash, result.totalBidAmount
            );
        }
    }
}

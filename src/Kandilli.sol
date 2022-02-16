// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.11;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {VRFConsumerBase} from "@chainlink/contracts/src/v0.8/VRFConsumerBase.sol";
import {Counters} from "@openzeppelin/contracts/utils/Counters.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "solmate/utils/ReentrancyGuard.sol";
import {IKandilli} from "./interfaces/IKandilli.sol";
import {IWETH} from "./interfaces/IWETH.sol";
import {IAuctionable} from "./interfaces/IAuctionable.sol";
import {Helpers} from "./lib/Helpers.sol";
import {console} from "./test/utils/Console.sol";

/**
 * @title Kandilli: Optimistic Candle Auctions
 * @author Ismet Ufuk Altinok (ism.eth)
 */
contract Kandilli is IKandilli, Ownable, VRFConsumerBase, ReentrancyGuard {
    using Counters for Counters.Counter;
    using SafeERC20 for IERC20;

    IWETH immutable weth;

    IAuctionable internal auctionable;

    bytes32 internal keyHash;

    uint256 internal vrfFee;

    Counters.Counter private auctionId;

    mapping(uint256 => Kandil) public kandilAuctions;

    KandilAuctionSettings public settings;

    mapping(bytes32 => uint256) private vrfRequestIdToAuctionId;

    uint32[] internal baseFeeObservations;

    bool initialized;

    /**
     * @param _auctionable Any token that implements IAuctionable
     * @param _initialSettings Initial KandilHouseSettings
     * @param _initBaseFeeObservations Initial base fee observations
     * @param _weth Wrapper Eth token address
     * @param _linkToken Chainlink token address in current chain
     * @param _vrfCoordinator Chainlink VRF coordinator address
     * @param _vrfFee Chainlink VRF fee, changes depending on chain
     * @param _keyHash Chainlink VRF key hash
     */
    constructor(
        IAuctionable _auctionable,
        KandilAuctionSettings memory _initialSettings,
        uint32[] memory _initBaseFeeObservations,
        address _weth,
        address _linkToken,
        address _vrfCoordinator,
        uint256 _vrfFee,
        bytes32 _keyHash
    ) VRFConsumerBase(_vrfCoordinator, _linkToken) {
        auctionable = _auctionable;
        weth = IWETH(_weth);
        settings = _initialSettings;
        baseFeeObservations = _initBaseFeeObservations;

        vrfFee = _vrfFee;
        keyHash = _keyHash;
    }

    function init() external onlyOwner {
        if (initialized) {
            revert AlreadyInitialized();
        }
        initialized = true;
        startNewAuction();
    }

    function startNewAuction() internal {
        auctionId.increment();

        Kandil storage kandil = kandilAuctions[auctionId.current()];
        kandil.startTime = uint64(block.timestamp);
        kandil.minBidAmount = _getCurrentMinimumBidAmount();
        kandil.auctionState = KandilState.Running;
        kandil.targetBaseFee = _getTargetBaseFee();
        kandil.settings = settings;

        emit AuctionStarted(auctionId.current(), block.timestamp);
    }

    /**
     * @notice Bid on an auction, an address can bid many times on the same auction all bids
     * will be saved seperately. To increase a specific bid, use increaseAmountOfBid.
     * @dev Bidding only touches 1 storage slot. Bid amount is saved as gwei to keep bid gas as low as possible.
     * Therefore cannot bid lower than gwei precision.
     * @param _auctionId Auction id
     * @return Array index of the bid, can be used to increase bid directly.
     */
    function addBidToAuction(uint256 _auctionId) external payable override returns (uint256) {
        if (msg.value % (1 gwei) != 0) {
            revert BidWithPrecisionLowerThanGwei();
        }

        Kandil storage currentAuction = kandilAuctions[_auctionId];
        if (currentAuction.auctionState != KandilState.Running) {
            revert AuctionIsNotRunning();
        }
        if (getAuctionDefiniteEndTime(_auctionId) <= block.timestamp) {
            revert CannotBidAfterAuctionEndTime();
        }
        if (msg.value < uint256(currentAuction.minBidAmount * (1 gwei))) {
            revert MinimumBidAmountNotMet();
        }

        // @dev: Notice bid amount is converted to gwei and use uint32 for time passed from start.
        currentAuction.bids.push(
            KandilBid({
                bidder: payable(msg.sender),
                timePassedFromStart: int32(uint32(uint64(block.timestamp) - uint64(currentAuction.startTime))),
                bidAmount: uint64(msg.value / (1 gwei))
            })
        );

        emit AuctionBid(msg.sender, _auctionId, currentAuction.bids.length - 1, msg.value);

        return currentAuction.bids.length - 1;
    }

    /**
     * @notice Increase an already existing bid with bid index.
     * @dev Bid amount is saved as gwei to keep bid gas as low as possible.
     * Bidding only touches 1 storage slot. Therefore cannot bid lower than gwei precision.
     * @param _auctionId Auction id
     * @param _bidIndex Index of the bid to increase
     */
    function increaseAmountOfBid(uint256 _auctionId, uint256 _bidIndex) external payable override {
        if (msg.value % (1 gwei) != 0) {
            revert BidWithPrecisionLowerThanGwei();
        }

        Kandil storage currentAuction = kandilAuctions[_auctionId];

        if (currentAuction.auctionState != KandilState.Running) {
            revert AuctionIsNotRunning();
        }
        if (getAuctionDefiniteEndTime(_auctionId) <= block.timestamp) {
            revert CannotBidAfterAuctionEndTime();
        }
        if (currentAuction.bids[_bidIndex].bidder != msg.sender) {
            revert CannotIncreaseBidForNonOwnedBid();
        }

        // @dev Here we convert the bid amount into gwei
        currentAuction.bids[_bidIndex].bidAmount += uint64(msg.value / (1 gwei));
        // @dev Every time a bidder increase bid, timestamp is reset to current time.
        currentAuction.bids[_bidIndex].timePassedFromStart = int32(
            uint32(uint64(block.timestamp) - uint64(currentAuction.startTime))
        );

        emit AuctionBidIncrease(msg.sender, _auctionId, _bidIndex, msg.value);
    }

    /**
     * @notice This function requests Chainlink VRF for a random number. Once the VRF is called back we know the
     * auction's actual ending time. Anyone can call this function once an auction is passed the definiteEndtime
     * to collect a bounty later on.  The bounty periodically increases and targets initally to gas cost to call
     * this function * targetBaseFee. Bounty isn't paid immediately because we cannot know if there will be any bids
     * before the snuff time without iterating through the bids (which we obviously don't want).
     * It also attempts to starts the next auction.
     */
    function retroSnuffCandle(uint256 _auctionId) external override returns (bytes32 requestId) {
        Kandil storage currentAuction = kandilAuctions[_auctionId];
        if (currentAuction.auctionState != KandilState.Running) {
            revert CannotSnuffCandleForNotRunningAuction();
        }
        if (block.timestamp < getAuctionDefiniteEndTime(_auctionId)) {
            revert CannotSnuffCandleBeforeDefiniteEndTime();
        }
        // If there's no bids, move on to the next auction.
        // Here we don't pay any bounty as we don't have any funds.
        // This will probably will be called by auction house.
        if (currentAuction.bids.length == 0) {
            currentAuction.auctionState = KandilState.EndedWithoutBids;
            startNewAuction();
            requestId = bytes32(0);
            emit CandleSnuffed(msg.sender, _auctionId, requestId);
            return requestId;
        }
        if (currentAuction.settings.snuffRequiresSendingLink) {
            if (LINK.balanceOf(msg.sender) < vrfFee) {
                revert UserDontHaveEnoughLinkToAskForVRF();
            }
            bool linkDepositSuccess = LINK.transferFrom(msg.sender, address(this), vrfFee);
            if (!linkDepositSuccess) {
                revert LinkDepositFailed();
            }
        }

        if (LINK.balanceOf(address(this)) < vrfFee) {
            revert HouseDontHaveEnoughLinkToAskForVRF();
        }

        currentAuction.auctionState = KandilState.WaitingVRFResult;
        requestId = requestRandomness(keyHash, vrfFee);
        vrfRequestIdToAuctionId[requestId] = _auctionId;

        startNewAuction();

        currentAuction.snuff.potentialBounty = _getAuctionRetroSnuffBounty(currentAuction, _auctionId);
        currentAuction.snuff.sender = payable(msg.sender);
        currentAuction.snuff.timestamp = uint64(block.timestamp);

        emit CandleSnuffed(msg.sender, _auctionId, requestId);
    }

    /**
     * @notice Anyone can propose winners after the VRF is set. Proposer needs to follow bidder sorting algorithm
     * to send winners with an array of bid index. Proposer needs to deposit an amount so that if proposer
     * propose a fraud winners list, anyone can challenge the proposal and get proposer's deposit as bounty.
     * If proposer is not challenged within the fraud challenge period, proposer will get
     * his deposit + a proposer bounty as reward.
     * @dev We only save proposed bid id array's hash. We only need this as we can check proposed ids authenticity
     * when we see again in calldata by checking hash against the recorded hash.
     * @param _auctionId Auction id
     * @param _winnerBidIds Sorted array of winner bid indexes. Array should be equal or lower than maxWinnersPerAuction.
     * @param _hash keccak256 hash of the winnerBidIds + vrfResult.
     * @param _totalBidAmount Sum of all bid amounts in winner bids.
     */
    function proposeWinners(
        uint256 _auctionId,
        uint32[] calldata _winnerBidIds,
        bytes32 _hash,
        uint64 _totalBidAmount
    ) external payable override {
        Kandil storage currentAuction = kandilAuctions[_auctionId];
        if (currentAuction.auctionState != KandilState.VRFSet) {
            revert CannotProposeWinnersBeforeVRFSetOrWhenWinnersAlreadyPosted();
        }

        if (keccak256(abi.encodePacked(_winnerBidIds, currentAuction.vrfResult)) != _hash) {
            revert IncorrectHashForWinnerBids();
        }

        //TODO: Deposit should be based on number of winners as challenge cost will be based on number of winners.
        //TODO: Should probably have a base deposit + maxWinnersPerAuction * 21000
        if (msg.value != (currentAuction.settings.winnersProposalDepositAmount * (1 gwei))) {
            revert DepositAmountForWinnersProposalNotMet();
        }
        uint64 proposalBounty = _getAuctionWinnersProposalBounty(currentAuction, _auctionId);
        // Here we check how much extra we have to give for bounty. If all the bids are minBidAmount, it means
        // we don't have any bounty to give.
        uint64 totalMinBids = uint64(_winnerBidIds.length) * currentAuction.minBidAmount;
        if (_totalBidAmount > totalMinBids) {
            uint64 extraFunds = _totalBidAmount - totalMinBids;
            proposalBounty = proposalBounty < extraFunds ? proposalBounty : extraFunds;
        } else {
            // No bounty for proposing winners as we haven't got extra from bids. We prioritize auctionable settling.
            proposalBounty = 0;
        }

        // Also re-calculate snuff bounty. On snuff time we didn't have data to calculate snuff bounty accurately
        // as we didn't have total bid amount.
        uint64 potentialSnuffBounty = currentAuction.snuff.potentialBounty;
        // Here we check how much extra we have to give for bounty. We also need to substract winners proposal bounty.
        if (_totalBidAmount > totalMinBids + proposalBounty) {
            uint64 extraFunds = _totalBidAmount - totalMinBids - proposalBounty;
            currentAuction.snuff.bounty = potentialSnuffBounty < extraFunds ? potentialSnuffBounty : extraFunds;
        } else {
            currentAuction.snuff.bounty = 0;
        }
        currentAuction.winnersProposal = KandilWinnersProposal({
            bounty: proposalBounty,
            totalBidAmount: _totalBidAmount,
            keccak256Hash: _hash,
            winnerCount: uint32(_winnerBidIds.length),
            sender: payable(msg.sender),
            timestamp: uint64(block.timestamp),
            isBountyClaimed: false
        });
        currentAuction.auctionState = KandilState.WinnersProposed;

        emit AuctionWinnersProposed(msg.sender, _auctionId, _hash);
    }

    /**
     * @notice Most critical function. Anyone can challenge the winners proposal by sending winner proposal data and
     *      a bid index that should have been included but haven't. If the proposal incorrectness is due
     *      to anything other than not included bid, _bidIndexToInclude should be set to 0. In that case,
     *      as other issues will be checked, we must be able to detect the fraud.
     * @param _auctionId Auction id
     * @param _winnerBidIndexes Sorted array of winner bid indexes.
     * @param _hash keccak256 hash of the winnerBidIds + vrfResult.
     * @param _bidIndexToInclude Index of the bid that should have been included but wasn't. 0xFFFFFFFF if the fault
     *      is either wront totalBidAmount or some of the included bids are after snuff time
     *      and shouldn't have been included.
     */
    function challengeProposedWinners(
        uint256 _auctionId,
        uint32[] calldata _winnerBidIndexes,
        bytes32 _hash,
        uint32 _bidIndexToInclude
    ) external override nonReentrant {
        Kandil storage currentAuction = kandilAuctions[_auctionId];

        if (currentAuction.auctionState != KandilState.WinnersProposed) {
            revert CannotChallengeWinnersProposalBeforePosted();
        }

        if (currentAuction.winnersProposal.timestamp + currentAuction.settings.fraudChallengePeriod < uint64(block.timestamp)) {
            revert CannotChallengeWinnersProposalAfterChallengePeriodIsOver();
        }

        if (keccak256(abi.encodePacked(_winnerBidIndexes, currentAuction.vrfResult)) != _hash) {
            revert WinnerProposalDataDoesntHaveCorrectHash();
        }

        if (currentAuction.winnersProposal.keccak256Hash != _hash) {
            revert WinnerProposalHashDoesntMatchPostedHash();
        }

        if (currentAuction.winnersProposal.sender == msg.sender) {
            revert CannotChallengeSelfProposal();
        }

        // Simple sanity checks
        // Check if amount of bids can satisfy proposed winner count
        if (currentAuction.bids.length < _winnerBidIndexes.length) {
            return _challengeSucceeded(currentAuction, _auctionId, 1);
        }

        // Check no duplicates in proposed winner bid indexes
        if (Helpers.checkDuplicates(_winnerBidIndexes)) {
            return _challengeSucceeded(currentAuction, _auctionId, 2);
        }

        // Check if bidIdToInclude is in the list.
        // When bidIdToInclude won't be used in detection, should be sent as 0xFFFFFFFF.
        if (_bidIndexToInclude != 0xFFFFFFFF && _bidIndexToInclude >= currentAuction.bids.length) {
            revert ChallengeFailedBidIdToIncludeIsNotInBidList();
        }

        // Check if bidIdToInclude is in the list of bids that is before snuff time.
        uint32 inclIndex = _bidIndexToInclude == 0xFFFFFFFF ? 0 : _bidIndexToInclude;
        KandilBid storage bidToInclude = currentAuction.bids[inclIndex];
        if (
            _bidIndexToInclude != 0xFFFFFFFF &&
            uint256(currentAuction.startTime) + uint256(uint32(bidToInclude.timePassedFromStart)) >
            getAuctionCandleSnuffedTime(_auctionId)
        ) {
            revert ChallengeFailedBidToIncludeIsNotBeforeSnuffTime();
        }

        KandilBidWithIndex[] memory nBids = new KandilBidWithIndex[](_winnerBidIndexes.length + 1);
        uint256 totalBidAmount = 0;
        for (uint32 i = 0; i < _winnerBidIndexes.length; i++) {
            // Check if bidIdToInclude is already in _winnerBidIds.
            if (_winnerBidIndexes[i] == _bidIndexToInclude) {
                revert ChallengeFailedBidIdToIncludeAlreadyInWinnerList();
            }
            // Check if winner proposal have any index higher than actual bids length.
            if (currentAuction.bids.length <= _winnerBidIndexes[i]) {
                return _challengeSucceeded(currentAuction, _auctionId, 3);
            }

            KandilBid storage bid = currentAuction.bids[_winnerBidIndexes[i]];
            // Check if any bid in the proposal is sent after the snuff time.
            if (
                uint256(currentAuction.startTime) + uint256(uint32(bid.timePassedFromStart)) >
                getAuctionCandleSnuffedTime(_auctionId)
            ) {
                return _challengeSucceeded(currentAuction, _auctionId, 4);
            }

            totalBidAmount += bid.bidAmount;
            nBids[i] = KandilBidWithIndex(bid.bidder, bid.timePassedFromStart, bid.bidAmount, _winnerBidIndexes[i]);
        }

        if (totalBidAmount != currentAuction.winnersProposal.totalBidAmount) {
            return _challengeSucceeded(currentAuction, _auctionId, 6);
        }
        if (_bidIndexToInclude != 0xFFFFFFFF) {
            // Add bid to include to the list of bids and sort again. If any items order changes, the challenge will succeed.
            nBids[_winnerBidIndexes.length] = KandilBidWithIndex(
                bidToInclude.bidder,
                bidToInclude.timePassedFromStart,
                bidToInclude.bidAmount,
                _bidIndexToInclude
            );
        }
        // Depending on contract size, sorting functions can be either in the contract or lib.
        // Having in library have extra gas cost because of copy.
        // _sortBids(nBids);
        nBids = Helpers.sortBids(nBids);
        for (uint32 i = 0; i < _winnerBidIndexes.length; i++) {
            if (nBids[i].index != _winnerBidIndexes[i]) {
                return _challengeSucceeded(currentAuction, _auctionId, 7);
            }
        }

        revert ChallengeFailedWinnerProposalIsCorrect();
    }

    function _challengeSucceeded(
        Kandil storage currentAuction,
        uint256 _auctionId,
        uint256 reason
    ) internal {
        emit ChallengeSucceded(msg.sender, _auctionId, reason);

        currentAuction.winnersProposal.bounty = 0;
        currentAuction.winnersProposal.keccak256Hash = 0;
        currentAuction.winnersProposal.sender = payable(address(0));
        currentAuction.winnersProposal.timestamp = 0;
        currentAuction.auctionState = KandilState.VRFSet;
        _safeTransferETHWithFallback(msg.sender, (currentAuction.settings.winnersProposalDepositAmount * (1 gwei)));
    }

    function claimWinnersProposalBounty(uint256 _auctionId) external override nonReentrant {
        Kandil storage currentAuction = kandilAuctions[_auctionId];

        if (currentAuction.auctionState != KandilState.WinnersProposed) {
            revert CannotClaimWinnersProposalBountyBeforePosted();
        }

        if (msg.sender != currentAuction.winnersProposal.sender) {
            revert CannotClaimWinnersProposalBountyIfNotProposer();
        }

        if (currentAuction.winnersProposal.timestamp + currentAuction.settings.fraudChallengePeriod >= uint64(block.timestamp)) {
            revert CannotClaimWinnersProposalBountyBeforeChallengePeriodIsOver();
        }

        if (currentAuction.winnersProposal.isBountyClaimed) {
            revert WinnersProposalBountyAlreadyClaimed();
        }

        if (currentAuction.winnersProposal.bounty == 0) {
            revert WinnersProposalBountyIsZero();
        }

        uint256 bounty = (currentAuction.winnersProposal.bounty + currentAuction.settings.winnersProposalDepositAmount) *
            (1 gwei);

        currentAuction.winnersProposal.isBountyClaimed = true;

        _safeTransferETHWithFallback(msg.sender, bounty);

        emit WinnersProposalBountyClaimed(msg.sender, _auctionId, bounty);
    }

    function claimSnuffBounty(uint256 _auctionId) external override nonReentrant {
        Kandil storage currentAuction = kandilAuctions[_auctionId];

        if (currentAuction.auctionState != KandilState.WinnersProposed) {
            revert CannotClaimSnuffBountyBeforeWinnersProposed();
        }

        if (msg.sender != currentAuction.snuff.sender) {
            revert CannotClaimSnuffBountyBeforeIfNotSnuffer();
        }

        if (currentAuction.winnersProposal.timestamp + currentAuction.settings.fraudChallengePeriod >= uint64(block.timestamp)) {
            revert CannotClaimSnuffBountyBeforeChallengePeriodIsOver();
        }

        if (currentAuction.snuff.isBountyClaimed) {
            revert SnuffBountyAlreadyClaimed();
        }

        if (currentAuction.snuff.bounty == 0) {
            revert SnuffBountyIsZero();
        }

        _safeTransferETHWithFallback(currentAuction.snuff.sender, (currentAuction.snuff.bounty * (1 gwei)));

        emit SnuffBountyClaimed(currentAuction.snuff.sender, _auctionId, currentAuction.snuff.bounty);
    }

    function withdrawLostBid(
        uint256 _auctionId,
        uint256 _bidIndex,
        bytes32 _hash,
        uint32[] calldata _winnerBidIds
    ) external override nonReentrant {
        Kandil storage currentAuction = kandilAuctions[_auctionId];
        if (currentAuction.auctionState != KandilState.WinnersProposed) {
            revert CannotWithdrawLostBidBeforeWinnersProposed();
        }

        if (currentAuction.winnersProposal.timestamp + currentAuction.settings.fraudChallengePeriod >= uint64(block.timestamp)) {
            revert CannotWithdrawLostBidBeforeChallengePeriodEnds();
        }

        if (keccak256(abi.encodePacked(_winnerBidIds, currentAuction.vrfResult)) != _hash) {
            revert WinnerProposalDataDoesntHaveCorrectHash();
        }

        if (currentAuction.winnersProposal.keccak256Hash != _hash) {
            revert WinnerProposalHashDoesntMatchPostedHash();
        }

        for (uint256 i = 0; i < _winnerBidIds.length; i++) {
            if (_bidIndex == _winnerBidIds[i]) {
                revert CannotWithdrawLostBidIfIncludedInWinnersProposal();
            }
        }

        if (currentAuction.bids[_bidIndex].timePassedFromStart == -1) {
            revert CannotWithdrawAlreadyWithdrawnBid();
        }

        if (currentAuction.bids[_bidIndex].bidder != msg.sender) {
            revert CannotWithdrawBidIfNotSender();
        }

        currentAuction.bids[_bidIndex].timePassedFromStart = -1;

        uint256 amount = uint256(currentAuction.bids[_bidIndex].bidAmount) * (1 gwei);
        _safeTransferETHWithFallback(msg.sender, amount);

        emit LostBidWithdrawn(msg.sender, _auctionId, _bidIndex);
    }

    /**
     * @notice Anyone can execute to claim a token but it will be settled for the bidder
     * and minimum bid amount will be sent to the caller of this function. This way NFT can be minted
     * anytime by anyone at the most profitable (least congested) time.
     */
    function claimWinningBid(
        uint256 _auctionId,
        bytes32 _hash,
        uint32[] calldata _winnerBidIds,
        uint256 _winnerBidIdIndex
    ) external override nonReentrant {
        Kandil storage currentAuction = kandilAuctions[_auctionId];
        if (_winnerBidIdIndex >= _winnerBidIds.length) {
            revert BidIdDoesntExist();
        }
        uint32 bidIndex = _winnerBidIds[_winnerBidIdIndex];
        if (
            currentAuction.bids.length <= bidIndex ||
            currentAuction.bids[bidIndex].bidder == address(0) ||
            currentAuction.bids[bidIndex].bidAmount == 0
        ) {
            revert BidIdDoesntExist();
        }

        if (currentAuction.auctionState != KandilState.WinnersProposed) {
            revert CannotClaimAuctionItemBeforeWinnersProposed();
        }

        if (currentAuction.winnersProposal.timestamp + currentAuction.settings.fraudChallengePeriod >= uint64(block.timestamp)) {
            revert CannotClaimAuctionItemBeforeChallengePeriodEnds();
        }

        if (keccak256(abi.encodePacked(_winnerBidIds, currentAuction.vrfResult)) != _hash) {
            revert WinnerProposalDataDoesntHaveCorrectHash();
        }

        if (currentAuction.winnersProposal.keccak256Hash != _hash) {
            revert WinnerProposalHashDoesntMatchPostedHash();
        }

        if (currentAuction.bids[bidIndex].timePassedFromStart == -1) {
            revert BidAlreadyClaimed();
        }

        currentAuction.bids[bidIndex].timePassedFromStart = -1;

        auctionable.settle(
            currentAuction.bids[bidIndex].bidder,
            uint256(keccak256(abi.encodePacked(currentAuction.vrfResult, bidIndex, "EnTrOpy")))
        );

        // Calculate bounty based on minBidAmount.
        _safeTransferETHWithFallback(msg.sender, uint256(currentAuction.minBidAmount * (1 gwei)));

        recordBaseFeeObservation();

        emit WinningBidClaimed(msg.sender, _auctionId, bidIndex, currentAuction.bids[bidIndex].bidder);
    }

    function moveAuctionFundsToOwner(uint256 _auctionId) external override nonReentrant {
        Kandil storage currentAuction = kandilAuctions[_auctionId];
        if (currentAuction.auctionState != KandilState.WinnersProposed) {
            revert CannotMoveFundsBeforeWinnersProposed();
        }

        if (currentAuction.winnersProposal.timestamp + currentAuction.settings.fraudChallengePeriod >= uint64(block.timestamp)) {
            revert CannotMoveFundsBeforeChallengePeriodEnds();
        }

        // Calculate all bounties.
        uint256 paidBounties = (currentAuction.winnersProposal.winnerCount * (currentAuction.minBidAmount * (1 gwei))) +
            (currentAuction.snuff.bounty * (1 gwei)) +
            (currentAuction.winnersProposal.bounty * (1 gwei));

        uint256 totalAmount = uint256(currentAuction.winnersProposal.totalBidAmount * (1 gwei)) - paidBounties;
        _safeTransferETHWithFallback(owner(), totalAmount);
    }

    /**
     * @notice Configure kandil house to whether to require depositing LINK while calling snuff.
     * If this is false, LINK needs to be deposited to the contract externally.
     */
    function setAuctionRequiresLink(bool _requiresLink) external onlyOwner {
        settings.snuffRequiresSendingLink = _requiresLink;
    }

    /**
     *  @notice This function will be called with a random uint256 which will be used to find out candle snuff time.
     *  @dev Should only be called by Chainlink when the VRF result is available.
     *  @dev Should not contain too much gas consuming logic. (limit to 200k gas)
     */
    function fulfillRandomness(bytes32 _requestId, uint256 _randomness) internal override {
        Kandil storage currentAuction = kandilAuctions[vrfRequestIdToAuctionId[_requestId]];
        if (currentAuction.auctionState != KandilState.WaitingVRFResult) {
            revert ReceiveVRFWhenNotExpecting();
        }

        currentAuction.vrfResult = _randomness;
        currentAuction.vrfSetTime = uint32(uint64(block.timestamp) - uint64(currentAuction.startTime));
        currentAuction.auctionState = KandilState.VRFSet;

        recordBaseFeeObservation();
    }

    /**
     * @notice Probabilistic storage of base fee observations.
     */
    function recordBaseFeeObservation() internal {
        uint256 index = block.number != 0 ? uint256(blockhash(block.number - 1)) % 10 : 0;
        baseFeeObservations[index] = uint32(block.basefee / (1 gwei));
    }

    function getAuctionMinimumBidAmount(uint256 _auctionId) external view returns (uint256) {
        Kandil storage currentAuction = kandilAuctions[_auctionId];
        return uint256(currentAuction.minBidAmount * (1 gwei));
    }

    /**
     * @notice Get list of bids for an auction.
     * @dev Around 14k bids without hitting limit on infura, or around 1.4k at normal gas limits of Ethereum. (30M).
     * @param _auctionId The auction id.
     * @param _page The page number.
     * @param _limit The number of bids to return per page. If both page & limit are 0, returns all bids.
     */
    function getAuctionBids(
        uint256 _auctionId,
        uint256 _page,
        uint256 _limit
    ) external view override returns (KandilBid[] memory) {
        Kandil storage currentAuction = kandilAuctions[_auctionId];
        if (_page == 0 && _limit == 0) {
            return currentAuction.bids;
        }
        uint256 lm = currentAuction.bids.length >= (_page * _limit) + _limit
            ? _limit
            : currentAuction.bids.length - (_page * _limit);
        KandilBid[] memory bids = new KandilBid[](lm);
        for (uint256 i = 0; i < lm; i++) {
            bids[i] = currentAuction.bids[(_page * lm) + i];
        }
        return bids;
    }

    function getClaimWinningBidBounty(uint256 _auctionId) public view returns (uint256) {
        Kandil storage currentAuction = kandilAuctions[_auctionId];
        return uint256(currentAuction.minBidAmount * (1 gwei));
    }

    /**
     * @notice Get the candle's actual snuffed time based on vrfResult and snuffPercentage
     */
    function getAuctionCandleSnuffedTime(uint256 _auctionId) public view returns (uint256) {
        return
            getAuctionDefiniteEndTime(_auctionId) -
            (kandilAuctions[_auctionId].vrfResult %
                (((getAuctionDefiniteEndTime(_auctionId) - uint256(kandilAuctions[_auctionId].startTime)) / 100) *
                    kandilAuctions[_auctionId].settings.snuffPercentage));
    }

    function getAuctionStartTime(uint256 _auctionId) public view returns (uint256) {
        return uint256(kandilAuctions[_auctionId].startTime);
    }

    function getAuctionState(uint256 _auctionId) public view returns (KandilState) {
        return kandilAuctions[_auctionId].auctionState;
    }

    function getAuctionDefiniteEndTime(uint256 _auctionId) public view returns (uint256) {
        return uint256(kandilAuctions[_auctionId].startTime + kandilAuctions[_auctionId].settings.auctionTotalDuration);
    }

    function getAuctionWinnerProposalTime(uint256 _auctionId) public view returns (uint256) {
        return uint256(kandilAuctions[_auctionId].winnersProposal.timestamp);
    }

    function getAuctionVRFSetTime(uint256 _auctionId) public view returns (uint256) {
        return uint256(kandilAuctions[_auctionId].startTime + kandilAuctions[_auctionId].vrfSetTime);
    }

    function getAuctionSnuffPercentage(uint256 _auctionId) external view returns (uint256) {
        return uint256(kandilAuctions[_auctionId].settings.snuffPercentage);
    }

    /**
     * @notice Get the potential snuff bounty before calling the snuff. After snuff bounty could be as low as 0,
     * due to not having enough bid amount (after snuff time) to cover snuff bounty.
     */
    function getAuctionPotentialRetroSnuffBounty(uint256 _auctionId) public view returns (uint256) {
        Kandil storage currentAuction = kandilAuctions[_auctionId];
        return _getAuctionRetroSnuffBounty(currentAuction, _auctionId) * (1 gwei);
    }

    function getAuctionPotentialWinnersProposalBounty(uint256 _auctionId) public view returns (uint256) {
        Kandil storage currentAuction = kandilAuctions[_auctionId];
        return _getAuctionWinnersProposalBounty(currentAuction, _auctionId) * (1 gwei);
    }

    /**
     * @notice Before winners proposal, this will be always 0.
     */
    function getAuctionRetroSnuffBounty(uint256 _auctionId) public view returns (uint256) {
        Kandil storage currentAuction = kandilAuctions[_auctionId];
        return currentAuction.snuff.bounty * (1 gwei);
    }

    /**
     * @notice Before winners proposal, this will be always 0.
     */
    function getAuctionWinnersProposalBounty(uint256 _auctionId) public view returns (uint256) {
        Kandil storage currentAuction = kandilAuctions[_auctionId];
        return currentAuction.winnersProposal.bounty * (1 gwei);
    }

    function getAuctionMaxWinnerCount(uint256 _auctionId) external view returns (uint256 r) {
        r = kandilAuctions[_auctionId].settings.maxWinnersPerAuction;
    }

    function getAuctionVRF(uint256 _auctionId) external view returns (uint256 r) {
        r = kandilAuctions[_auctionId].vrfResult;
    }

    function getAuctionRequiredWinnersProposalDeposit(uint256 _auctionId) external view returns (uint256 r) {
        r = uint256(kandilAuctions[_auctionId].settings.winnersProposalDepositAmount * (1 gwei));
    }

    /**
     * @notice Calculate the snuff bounty based on how much time passed since the auction definite end time.
     * It's calculated as:
     *      base bounty + (10% base bounty * multiplier)
     * where base bounty is gas cost * targetBaseFee which we roughly trying to keep track via observations and
     * multiplier is time passed since end of auction / 12. So every 12 seconds bounty increase by 0.1 base bounty.
     * Bounty can only go as high as 10x the gas cost of calling the snuff function.
     */
    function _calculateBounty(
        uint64 bountyBase,
        uint64 timeMultiplier,
        uint8 maxBountyMultiplier
    ) internal view returns (uint64) {
        return
            bountyBase + ((bountyBase / 10) * timeMultiplier) > bountyBase * maxBountyMultiplier
                ? bountyBase * maxBountyMultiplier
                : bountyBase + ((bountyBase / 10) * timeMultiplier);
    }

    function _getAuctionRetroSnuffBounty(Kandil storage currentAuction, uint256 _auctionId) internal view returns (uint64) {
        uint64 timePassed = uint64(block.timestamp - getAuctionDefiniteEndTime(_auctionId));
        uint64 timeMultiplier = timePassed / 12;
        uint64 bountyBase = (currentAuction.settings.retroSnuffGas * currentAuction.targetBaseFee);

        // WRONG we cannot know if we have bids before the snuff time. All bids might be after the snuff.
        // As we won't go through the bids array to see how much funds we have for bounties, we simply use the minimum bid
        // safe basis for the bounty. If we don't have enough bids to cover the calculated bounty we will pay based on
        // the minimum bid amounts. This amount might not even cover the gas cost of calling snuff but we don't have
        // other options. In such cases, auction house owner would probably call snuff. Also as we'll pay bounty for
        // winners proposal, we divide total minimum bounty by 2.
        //uint256 minimumAmountCollected = (currentAuction.minBidAmount * (1 gwei) * currentAuction.bids.length) / 2;
        //uint256 calculatedBounty = _calculateBounty(bountyBase, timeMultiplier, currentAuction.settings.maxBountyMultiplier);
        //return calculatedBounty < minimumAmountCollected ? calculatedBounty : minimumAmountCollected;

        return _calculateBounty(bountyBase, timeMultiplier, currentAuction.settings.maxBountyMultiplier);
    }

    function _getAuctionWinnersProposalBounty(Kandil storage currentAuction, uint256 _auctionId) internal view returns (uint64) {
        uint64 timePassed = uint64(block.timestamp - getAuctionVRFSetTime(_auctionId));
        uint64 timeMultiplier = timePassed / 12;
        uint64 bountyBase = (currentAuction.settings.winnersProposalGas * currentAuction.targetBaseFee);

        return _calculateBounty(bountyBase, timeMultiplier, currentAuction.settings.maxBountyMultiplier);
    }

    function _getTargetBaseFee() internal view returns (uint32) {
        uint32[] memory baseFeeObservationsCopy = baseFeeObservations;
        _sortBaseFeeObservations(baseFeeObservationsCopy, 0, int256(baseFeeObservationsCopy.length - 1));
        return (baseFeeObservations[0] + baseFeeObservations[1] + baseFeeObservations[2] + baseFeeObservations[3]) / 4;
    }

    function _sortBaseFeeObservations(
        uint32[] memory arr,
        int256 left,
        int256 right
    ) internal pure {
        int256 i = left;
        int256 j = right;
        if (i == j) return;
        uint256 pivot = arr[uint256(left + (right - left) / 2)];
        while (i <= j) {
            while (arr[uint256(i)] > pivot) i++;
            while (pivot > arr[uint256(j)]) j--;
            if (i <= j) {
                (arr[uint256(i)], arr[uint256(j)]) = (arr[uint256(j)], arr[uint256(i)]);
                i++;
                j--;
            }
        }
        if (left < j) _sortBaseFeeObservations(arr, left, j);
        if (i < right) _sortBaseFeeObservations(arr, i, right);
    }

    function _getCurrentMinimumBidAmount() internal view returns (uint64 minBid) {
        minBid = _getTargetBaseFee() * uint64(auctionable.getGasCost());
    }

    /**
     * @notice Transfer ETH. If the ETH transfer fails, wrap the ETH and try send it as WETH.
     */
    function _safeTransferETHWithFallback(address _to, uint256 _amount) internal {
        if (_amount == 0 || _to == address(0)) {
            revert EthTransferFailedDestOrAmountZero();
        }
        if (address(this).balance < _amount) {
            revert KandilInsolvent();
        }
        (bool success, ) = _to.call{value: _amount, gas: 30_000}(new bytes(0));
        if (!success) {
            weth.deposit{value: _amount}();
            IERC20(address(weth)).safeTransfer(_to, _amount);
        }
    }
}

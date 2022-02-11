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

    IAuctionable internal auctionToken;

    bytes32 internal keyHash;

    uint256 internal vrfFee;

    Counters.Counter private auctionId;

    mapping(uint256 => Kandil) public kandilAuctions;

    KandilAuctionSettings public settings;

    mapping(bytes32 => uint256) private vrfRequestIdToAuctionId;

    uint32[] internal baseFeeObservations;

    /**
     * @param _auctionToken Any token that implements IAuctionable
     * @param _initialSettings Initial KandilHouseSettings
     * @param _initBaseFeeObservations Initial base fee observations
     * @param _weth Wrapper Eth token address
     * @param _linkToken Chainlink token address in current chain
     * @param _vrfCoordinator Chainlink VRF coordinator address
     * @param _vrfFee Chainlink VRF fee, changes depending on chain
     * @param _keyHash Chainlink VRF key hash
     */
    constructor(
        IAuctionable _auctionToken,
        KandilAuctionSettings memory _initialSettings,
        uint32[] memory _initBaseFeeObservations,
        address _weth,
        address _linkToken,
        address _vrfCoordinator,
        uint256 _vrfFee,
        bytes32 _keyHash
    ) VRFConsumerBase(_vrfCoordinator, _linkToken) {
        auctionToken = _auctionToken;
        weth = IWETH(_weth);
        settings = _initialSettings;
        baseFeeObservations = _initBaseFeeObservations;

        vrfFee = _vrfFee;
        keyHash = _keyHash;
    }

    function init() external onlyOwner {
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
     * @dev Bid amount is saved as gwei to keep bid gas as low as possible.
     * Bidding only touches 1 storage slot. Therefore cannot bid lower than gwei precision.
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
                timePassedFromStart: uint32(uint64(block.timestamp) - uint64(currentAuction.startTime)),
                bidAmount: uint64(msg.value / (1 gwei)),
                isProcessed: false
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
     * @param _bidId Index of the bid to increase
     */
    function increaseAmountOfBid(uint256 _auctionId, uint256 _bidId) external payable override {
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
        if (currentAuction.bids[_bidId].bidder != msg.sender) {
            revert CannotIncreaseBidForNonOwnedBid();
        }

        // @dev Here we convert the bid amount into gwei
        currentAuction.bids[_bidId].bidAmount += uint64(msg.value / (1 gwei));
        // @dev Every time a bidder increase bid, timestamp is reset to current time.
        currentAuction.bids[_bidId].timePassedFromStart = uint32(uint64(block.timestamp) - uint64(currentAuction.startTime));

        emit AuctionBidIncrease(msg.sender, _auctionId, _bidId, msg.value);
    }

    /**
     * @notice This function requests Chainlink VRF for a random number. Once the VRF is called back we know the
     * auction's actual ending time. Anyone can call this function once an auction is passed the definiteEndtime
     * to collect a bounty.  The bounty periodically increases and targets initally to gas cost to call
     * this function * targetBaseFee. It also attempts to starts the next auction.
     */
    function retroSnuffCandle(uint256 _auctionId) external override returns (bytes32 requestId) {
        Kandil storage currentAuction = kandilAuctions[_auctionId];
        if (currentAuction.auctionState != KandilState.Running) {
            revert CannotSnuffCandleForNotRunningAuction();
        }
        if (block.timestamp < getAuctionDefiniteEndTime(_auctionId)) {
            revert CannotSnuffCandleBeforeDefiniteEndTime();
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

        currentAuction.paidSnuffReward = _getAuctionRetroSnuffBounty(currentAuction, _auctionId);
        _safeTransferETHWithFallback(msg.sender, currentAuction.paidSnuffReward);

        emit VRFRequested(msg.sender, _auctionId, requestId);
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
     * @param _winnerBidIds Sorted array of winner bid indexes. Array should be equal or lower than numWinnersPerAuction.
     * @param _hash keccak256 hash of the winnerBidIds + vrfResult.
     */
    function proposeWinners(
        uint256 _auctionId,
        uint32[] calldata _winnerBidIds,
        bytes32 _hash
    ) external payable override {
        Kandil storage currentAuction = kandilAuctions[_auctionId];
        if (currentAuction.auctionState != KandilState.VRFSet) {
            revert CannotProposeWinnersBeforeVRFSetOrWhenWinnersAlreadyPosted();
        }

        if (keccak256(abi.encodePacked(_winnerBidIds, currentAuction.vrfResult)) != _hash) {
            revert IncorrectHashForWinnerBids();
        }

        //TODO: Deposit should be based on number of winners as challenge cost will be based on number of winners.
        //TODO: Should probably have a base deposit + desiredNumWinners * 21000
        if (msg.value != (currentAuction.settings.winnersProposalDepositAmount * (1 gwei))) {
            revert DepositAmountForWinnersProposalNotMet();
        }

        currentAuction.winnersProposal = KandilWinnersProposal({
            reward: _getAuctionWinnersProposalBounty(currentAuction, _auctionId),
            keccak256Hash: _hash,
            winnerCount: uint32(_winnerBidIds.length),
            sender: payable(msg.sender),
            timestamp: uint64(block.timestamp)
        });
        currentAuction.auctionState = KandilState.WinnersPosted;

        emit AuctionWinnersProposed(msg.sender, _auctionId, _hash);
    }

    /**
     * @notice Most critical function. Anyone can challenge the winners proposal by sending winner proposal data and
     * a bid index that should have been included but haven't. If the proposal incorrectness is due to anything other
     * than not included bid, _bidIndexToInclude should be set to 0. In that case, as other issues will be checked, we
     * must be able to detect the fraud.
     */
    function challengeProposedWinners(
        uint256 _auctionId,
        uint32[] calldata _winnerBidIds,
        bytes32 _hash,
        uint32 _bidIndexToInclude
    ) external override nonReentrant {
        Kandil storage currentAuction = kandilAuctions[_auctionId];

        if (currentAuction.auctionState != KandilState.WinnersPosted) {
            revert CannotChallengeWinnersProposalBeforePosted();
        }

        if (currentAuction.winnersProposal.timestamp + currentAuction.settings.fraudChallengePeriod < uint64(block.timestamp)) {
            revert CannotChallengeWinnersProposalAfterChallengePeriodIsOver();
        }

        if (keccak256(abi.encodePacked(_winnerBidIds, currentAuction.vrfResult)) != _hash) {
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
        if (currentAuction.bids.length < _winnerBidIds.length) {
            return _challengeSucceeded(currentAuction, _auctionId, 1);
        }

        // Check no duplicates in proposed winner bid indexes
        if (Helpers.checkDuplicates(_winnerBidIds)) {
            return _challengeSucceeded(currentAuction, _auctionId, 2);
        }

        // Check if bidIdToInclude is in the list.
        // When bidIdToInclude won't be used in detection, should be sent as 0. If the auction has no bids at all,
        // there won't be a winners proposal anyway.
        if (_bidIndexToInclude >= currentAuction.bids.length) {
            revert ChallengeFailedBidIdToIncludeIsNotInBidList();
        }

        // Check if bidIdToInclude is in the list of bids that is before snuff time.
        KandilBid storage bidToInclude = currentAuction.bids[_bidIndexToInclude];
        if (
            uint256(currentAuction.startTime) + uint256(bidToInclude.timePassedFromStart) >
            getAuctionCandleSnuffedTime(_auctionId)
        ) {
            revert ChallengeFailedBidToIncludeIsNotBeforeSnuffTime();
        }

        KandilBidWithIndex[] memory nBids = new KandilBidWithIndex[](_winnerBidIds.length + 1);
        for (uint32 i = 0; i < _winnerBidIds.length; i++) {
            // Check if bidIdToInclude is already in _winnerBidIds.
            if (_winnerBidIds[i] == _bidIndexToInclude) {
                revert ChallengeFailedBidIdToIncludeAlreadyInWinnerList();
            }

            // Check if winner proposal have any index higher than actual bids length.
            if (currentAuction.bids.length <= _winnerBidIds[i]) {
                return _challengeSucceeded(currentAuction, _auctionId, 3);
            }

            KandilBid storage bid = currentAuction.bids[_winnerBidIds[i]];
            // Check if any bid in the proposal is sent after the snuff time.
            if (uint256(currentAuction.startTime) + uint256(bid.timePassedFromStart) > getAuctionCandleSnuffedTime(_auctionId)) {
                return _challengeSucceeded(currentAuction, _auctionId, 4);
            }
            // TODO: Check this.
            // Bid doesn't exist? How did this happen? Probably can remove this check.
            if (bid.bidder == payable(address(0))) {
                return _challengeSucceeded(currentAuction, _auctionId, 5);
            }
            nBids[i] = KandilBidWithIndex(bid.bidder, bid.timePassedFromStart, bid.bidAmount, bid.isProcessed, _winnerBidIds[i]);
        }

        // Add bid to include to the list of bids and sort again. If any items order changes, the challenge will succeed.
        nBids[_winnerBidIds.length] = KandilBidWithIndex(
            bidToInclude.bidder,
            bidToInclude.timePassedFromStart,
            bidToInclude.bidAmount,
            bidToInclude.isProcessed,
            _bidIndexToInclude
        );

        // Depending on contract size, sorting functions can be either in the contract or lib.
        // Having in library have extra gas cost because of copy.
        // _sortBids(nBids);
        nBids = Helpers.sortBids(nBids);
        for (uint32 i = 0; i < _winnerBidIds.length; i++) {
            if (nBids[i].index != _winnerBidIds[i]) {
                return _challengeSucceeded(currentAuction, _auctionId, 6);
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

        currentAuction.winnersProposal.reward = 0;
        currentAuction.winnersProposal.keccak256Hash = 0;
        currentAuction.winnersProposal.sender = payable(address(0));
        currentAuction.winnersProposal.timestamp = 0;
        currentAuction.auctionState = KandilState.VRFSet;
        _safeTransferETHWithFallback(msg.sender, (currentAuction.settings.winnersProposalDepositAmount * (1 gwei)));
    }

    function claimWinnersProposalReward(uint256 _auctionId) external override nonReentrant {
        Kandil storage currentAuction = kandilAuctions[_auctionId];

        if (currentAuction.auctionState != KandilState.WinnersPosted) {
            revert CannotClaimWinnersProposalRewardBeforePosted();
        }

        if (msg.sender != currentAuction.winnersProposal.sender) {
            revert CannotClaimWinnersProposalRewardIfNotProposer();
        }

        if (currentAuction.winnersProposal.timestamp + currentAuction.settings.fraudChallengePeriod > uint64(block.timestamp)) {
            revert CannotClaimWinnersProposalRewardBeforeChallengePeriodIsOver();
        }

        uint256 reward = currentAuction.winnersProposal.reward +
            (currentAuction.settings.winnersProposalDepositAmount * (1 gwei));

        _safeTransferETHWithFallback(msg.sender, reward);

        emit WinnersProposalRewardClaimed(_auctionId, msg.sender, reward);
    }

    function withdrawLostBid(
        uint256 _auctionId,
        uint256 _bidId,
        bytes32 _hash,
        uint32[] calldata _winnerBidIds
    ) external override nonReentrant {
        Kandil storage currentAuction = kandilAuctions[_auctionId];
        if (currentAuction.auctionState != KandilState.WinnersPosted || currentAuction.winnersProposal.timestamp == 0) {
            revert CannotWithdrawLostBidBeforeWinnersPosted();
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
            if (_bidId == _winnerBidIds[i]) {
                revert CannotWithdrawLostBidIfIncludedInWinnersProposal();
            }
        }

        if (currentAuction.bids[_bidId].isProcessed) {
            revert CannotWithdrawAlreadyWithdrawnBid();
        }

        if (currentAuction.bids[_bidId].bidder != msg.sender) {
            revert CannotWithdrawBidIfNotSender();
        }

        currentAuction.bids[_bidId].isProcessed = true;

        uint256 amount = uint256(currentAuction.bids[_bidId].bidAmount) * (1 gwei);
        _safeTransferETHWithFallback(msg.sender, amount);

        emit LostBidWithdrawn(_auctionId, _bidId, msg.sender);
    }

    /**
     * @notice Anyone can execute to claim a token but it will be settled for the bidder
     * and minimum bid amount will be sent to the caller of this function. This way NFT can be minted
     * anytime by anyone at the most profitable (least congested) time.
     */
    function claimWinningBid(
        uint256 _auctionId,
        uint256 _bidId,
        bytes32 _hash,
        uint32[] calldata _winnerBidIds,
        uint256 _winnerBidIdIndex
    ) external override nonReentrant {
        Kandil storage currentAuction = kandilAuctions[_auctionId];
        if (currentAuction.auctionState != KandilState.WinnersPosted || currentAuction.winnersProposal.timestamp == 0) {
            revert CannotClaimAuctionItemBeforeWinnersPosted();
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

        if (_winnerBidIds[_winnerBidIdIndex] != _bidId) {
            revert WinnerProposalBidIdDoesntMatch();
        }

        if (currentAuction.bids[_bidId].isProcessed) {
            revert BidAlreadyClaimed();
        }

        currentAuction.bids[_bidId].isProcessed = true;

        auctionToken.settle(
            currentAuction.bids[_bidId].bidder,
            uint256(keccak256(abi.encodePacked(currentAuction.vrfResult, _bidId, "EnTrOpy")))
        );

        // Calculate bounty based on minBidAmount - rewards paid for snuff and winners proposal.

        uint256 paidRewardPerWinner = (currentAuction.paidSnuffReward + currentAuction.winnersProposal.reward) /
            uint256(currentAuction.winnersProposal.winnerCount);
        _safeTransferETHWithFallback(msg.sender, uint256(currentAuction.minBidAmount * (1 gwei)) - paidRewardPerWinner);

        recordBaseFeeObservation();

        emit WinningBidClaimed(msg.sender, _auctionId, _bidId, currentAuction.bids[_bidId].bidder);
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
        return
            uint256(currentAuction.minBidAmount * (1 gwei)) -
            ((currentAuction.paidSnuffReward + currentAuction.winnersProposal.reward) /
                uint256(currentAuction.winnersProposal.winnerCount));
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

    function getAuctionDefiniteEndTime(uint256 _auctionId) public view returns (uint256) {
        return uint256(kandilAuctions[_auctionId].startTime + kandilAuctions[_auctionId].settings.auctionTotalDuration);
    }

    function getAuctionVRFSetTime(uint256 _auctionId) public view returns (uint256) {
        return uint256(kandilAuctions[_auctionId].startTime + kandilAuctions[_auctionId].vrfSetTime);
    }

    function getAuctionSnuffPercentage(uint256 _auctionId) external view returns (uint256) {
        return uint256(kandilAuctions[_auctionId].settings.snuffPercentage);
    }

    function getAuctionRetroSnuffBounty(uint256 _auctionId) public view returns (uint256) {
        Kandil storage currentAuction = kandilAuctions[_auctionId];
        return _getAuctionRetroSnuffBounty(currentAuction, _auctionId);
    }

    function getAuctionWinnerCount(uint256 _auctionId) external view returns (uint256 r) {
        r = kandilAuctions[_auctionId].settings.numWinnersPerAuction;
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
        uint256 bountyBase,
        uint256 timeMultiplier,
        uint8 maxBountyMultiplier
    ) internal view returns (uint256) {
        return
            bountyBase + ((bountyBase / 10) * timeMultiplier) > bountyBase * maxBountyMultiplier
                ? bountyBase * maxBountyMultiplier
                : bountyBase + ((bountyBase / 10) * timeMultiplier);
    }

    function _getAuctionRetroSnuffBounty(Kandil storage currentAuction, uint256 _auctionId) internal view returns (uint256) {
        uint256 timePassed = block.timestamp - getAuctionDefiniteEndTime(_auctionId);
        uint256 timeMultiplier = timePassed / 12;
        uint256 bountyBase = (currentAuction.settings.retroSnuffGas * currentAuction.targetBaseFee * 1 gwei);
        return _calculateBounty(bountyBase, timeMultiplier, currentAuction.settings.maxBountyMultiplier);
    }

    function _getAuctionWinnersProposalBounty(Kandil storage currentAuction, uint256 _auctionId) internal view returns (uint256) {
        uint256 timePassed = block.timestamp - getAuctionVRFSetTime(_auctionId);
        uint256 timeMultiplier = timePassed / 12;
        uint256 bountyBase = (currentAuction.settings.winnersProposalGas * currentAuction.targetBaseFee * 1 gwei);
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
        minBid = _getTargetBaseFee() * uint64(auctionToken.getGasCost());
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

    function _sortBids(IKandilli.KandilBidWithIndex[] memory nBids) internal pure {
        _sortBidByAmount(nBids, 0, int256(nBids.length - 1));
        for (uint256 i; i < nBids.length - 1; i++) {
            if (nBids[i].bidAmount == nBids[i + 1].bidAmount) {
                uint256 start = i;
                uint256 end;
                for (uint256 z = i + 1; z < nBids.length - 1; z++) {
                    if (nBids[z].bidAmount != nBids[z + 1].bidAmount) {
                        end = z;
                        break;
                    }
                }
                end = end == 0 ? nBids.length - 1 : end;
                _secondarySortBidsByIndex(nBids, int256(start), int256(end));
                i = end;
            }
        }
    }

    function _sortBidByAmount(
        IKandilli.KandilBidWithIndex[] memory arr,
        int256 left,
        int256 right
    ) private pure {
        int256 i = left;
        int256 j = right;
        if (i == j) return;
        uint256 pivot = arr[uint256(left + (right - left) / 2)].bidAmount;
        while (i <= j) {
            while (arr[uint256(i)].bidAmount > pivot) i++;
            while (pivot > arr[uint256(j)].bidAmount) j--;
            if (i <= j) {
                (arr[uint256(i)], arr[uint256(j)]) = (arr[uint256(j)], arr[uint256(i)]);
                i++;
                j--;
            }
        }
        if (left < j) _sortBidByAmount(arr, left, j);
        if (i < right) _sortBidByAmount(arr, i, right);
    }

    function _secondarySortBidsByIndex(
        IKandilli.KandilBidWithIndex[] memory arr,
        int256 left,
        int256 right
    ) private pure {
        int256 i = left;
        int256 j = right;
        if (i == j) return;
        uint256 pivot = arr[uint256(left + (right - left) / 2)].index;
        while (i <= j) {
            while (arr[uint256(i)].index < pivot) i++;
            while (pivot < arr[uint256(j)].index) j--;
            if (i <= j) {
                (arr[uint256(i)], arr[uint256(j)]) = (arr[uint256(j)], arr[uint256(i)]);
                i++;
                j--;
            }
        }
        if (left < j) _secondarySortBidsByIndex(arr, left, j);
        if (i < right) _secondarySortBidsByIndex(arr, i, right);
    }
}

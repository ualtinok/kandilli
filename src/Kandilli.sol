// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.0;

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
 * @author ism.eth
 * @notice An onchain gas optimized candle auction facilitator contract that uses optimistic auction settling
 *      via fraud proofs.
 */
contract Kandilli is IKandilli, Ownable, VRFConsumerBase, ReentrancyGuard {
    using Counters for Counters.Counter;
    using SafeERC20 for IERC20;

    // @notice wrapped eth
    IWETH public immutable weth;

    // @notice Contract that implements auctionable. Like an erc729 token.
    IAuctionable public immutable auctionable;

    // @notice keyHash for Chainlink VRF
    bytes32 public keyHash;

    // @notice fee for Chainlink VRF
    uint256 public vrfFee;

    // @notice auction id
    Counters.Counter public auctionId;

    // @notice map that holds all auctions with their respective auction id
    mapping(uint256 => Kandil) public kandilAuctions;

    // @notice settings for the auction, this is used inside the auction struct also.
    // Changes to the settings will only reflect when a new auction starts.
    KandilAuctionSettings public settings;

    // @notice Is auction house initialized
    bool public initialized;

    // @notice Chainlink VRF requests to auction id mapping.
    mapping(bytes32 => uint256) internal vrfRequestIdToAuctionId;

    // @notice Base fee observations recorded during claims.
    uint16[96] internal baseFeeObservations;

    /**
     * @param _auctionable Any token that implements IAuctionable
     * @param _initBaseFeeObservations Initial base fee observations
     * @param _weth Wrapper Eth token address
     * @param _linkToken Chainlink token address in current chain
     * @param _vrfCoordinator Chainlink VRF coordinator address
     * @param _vrfFee Chainlink VRF fee, changes depending on chain
     * @param _keyHash Chainlink VRF key hash
     */
    constructor(
        IAuctionable _auctionable,
        uint16[96] memory _initBaseFeeObservations,
        address _weth,
        address _linkToken,
        address _vrfCoordinator,
        uint256 _vrfFee,
        bytes32 _keyHash
    ) VRFConsumerBase(_vrfCoordinator, _linkToken) {
        auctionable = _auctionable;
        weth = IWETH(_weth);
        baseFeeObservations = _initBaseFeeObservations;

        vrfFee = _vrfFee;
        keyHash = _keyHash;
    }

    function init(KandilAuctionSettings memory _settings) external override onlyOwner {
        if (initialized) {
            revert AlreadyInitialized();
        }
        settings = _settings;
        initialized = true;
        startNewAuction();
    }

    function reset(KandilAuctionSettings memory _settings, uint256 _vrfFee) external override onlyOwner {
        settings = _settings;
        vrfFee = _vrfFee;
    }

    function startNewAuction() internal {
        auctionId.increment();

        Kandil storage kandil = kandilAuctions[auctionId.current()];
        kandil.startTime = uint40(block.timestamp);
        kandil.definiteEndTime = uint40(block.timestamp) + uint40(settings.auctionTotalDuration);
        kandil.minBidAmount = _getCurrentMinimumBidAmount();
        kandil.auctionState = KandilState.Running;
        kandil.targetBaseFee = _getTargetBaseFee();
        kandil.settings = settings;

        emit AuctionStarted(auctionId.current(), block.timestamp);
    }

    /**
     * @notice Bid on an auction, an address can bid many times on the same auction all bids
     *      will be saved seperately. To increase a specific bid, use increaseAmountOfBid.
     * @dev Bidding only touches 1 storage slot. Bid amount is saved as gwei to keep bid gas as low as possible.
     *      Therefore cannot bid lower than gwei precision.
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

        if (currentAuction.definiteEndTime <= block.timestamp) {
            revert CannotBidAfterAuctionEndTime();
        }

        if (msg.value < uint256(currentAuction.minBidAmount) * (1 gwei)) {
            revert MinimumBidAmountNotMet();
        }

        // @dev: Notice bid amount is converted to gwei and use uint32 for time passed from start.
        currentAuction.bids.push(
            KandilBid({
                bidder: payable(msg.sender),
                timestamp: uint40(block.timestamp),
                bidAmount: uint48(msg.value / (1 gwei)),
                isProcessed: false
            })
        );

        emit AuctionBid(msg.sender, _auctionId, currentAuction.bids.length - 1, msg.value);

        return currentAuction.bids.length - 1;
    }

    /**
     * @notice Increase an already existing bid with bid index.
     * @dev Bid amount is saved as gwei to keep bid gas as low as possible.
     *      Bidding only touches 1 storage slot. Therefore cannot bid lower than gwei precision.
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

        if (currentAuction.definiteEndTime <= block.timestamp) {
            revert CannotBidAfterAuctionEndTime();
        }

        if (currentAuction.bids[_bidIndex].bidder != msg.sender) {
            revert CannotIncreaseBidForNonOwnedBid();
        }

        // @dev Here we convert the bid amount into gwei
        currentAuction.bids[_bidIndex].bidAmount += uint48(msg.value / (1 gwei));
        // @dev Every time a bidder increase bid, timestamp is reset to current time.
        currentAuction.bids[_bidIndex].timestamp = uint40(block.timestamp); //int32(uint32(block.timestamp - uint256(currentAuction.startTime)));

        emit AuctionBidIncrease(msg.sender, _auctionId, _bidIndex, msg.value);
    }

    /**
     * @notice This function requests Chainlink VRF for a random number. Once the VRF is called back we know the
     * auction's actual ending time. Anyone can call this function once an auction total duration is finished
     * to collect a bounty later on.  The bounty periodically increases and targets initially to gas cost to call
     * this function * targetBaseFee. Bounty isn't paid immediately because we cannot know if there will be any bids
     * before the snuff time without iterating through the bids (which we obviously don't want).
     * It also attempts to starts the next auction.
     */
    function retroSnuffCandle(uint256 _auctionId) external override returns (bytes32 requestId) {
        Kandil storage currentAuction = kandilAuctions[_auctionId];
        if (currentAuction.auctionState != KandilState.Running) {
            revert CannotSnuffCandleForNotRunningAuction();
        }
        if (block.timestamp < currentAuction.definiteEndTime) {
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

        currentAuction.snuff.potentialBounty = _getAuctionRetroSnuffBounty(currentAuction);
        currentAuction.snuff.sender = payable(msg.sender);
        currentAuction.snuff.timestamp = uint40(block.timestamp);

        emit CandleSnuffed(msg.sender, _auctionId, requestId);
    }

    /**
     * @notice Anyone can propose winners after the VRF is set. Proposer needs to follow bid sorting algorithm
     *      to send winners with an array of bid index. Proposer needs to deposit an amount so that if proposer
     *      propose a fraud winners list, anyone can challenge the proposal and get proposer's deposit as bounty.
     *      If proposer is not challenged within the fraud challenge period, proposer will get
     *      his deposit + a proposer bounty as reward.
     * @dev We only save proposed bid id array's hash. We only need this as we can check proposed ids authenticity
     *      when we see again in calldata by checking hash against the recorded hash.
     * @param _auctionId Auction id
     * @param _winnerBidIndexesBytes Byte serialized uint16 array of winner bid indexes. Array should be equal or lower than maxWinnersPerAuction.
     * @param _hash keccak256 hash of the winnerBidIds + vrfResult.
     * @param _totalBidAmount Sum of all bid amounts in winner bids.
     */
    function proposeWinners(
        uint256 _auctionId,
        bytes calldata _winnerBidIndexesBytes,
        bytes32 _hash,
        uint64 _totalBidAmount
    ) external payable override {
        Kandil storage currentAuction = kandilAuctions[_auctionId];
        if (currentAuction.auctionState != KandilState.VRFSet) {
            revert CannotProposeWinnersBeforeVRFSetOrWhenWinnersAlreadyPosted();
        }

        if (keccak256(abi.encodePacked(_winnerBidIndexesBytes)) != _hash) {
            revert IncorrectHashForWinnerBids();
        }
        uint16[] memory _winnerBidIndexes = _bytesToUInt16Arr(_winnerBidIndexesBytes);

        /* TODO: Optimization: Can skip the fraud challenge period if there's very low amount of bids.
            Each bid to check will cost 1 slot to read (2100 gas). So if there's only 10 bids, total cost
            Deposit should be based on number of winners as challenge cost will be based on number of winners.
            Should probably have a base deposit + maxWinnersPerAuction * 21000
        */
        if (msg.value != uint256(currentAuction.settings.winnersProposalDepositAmount) * (1 gwei)) {
            revert DepositAmountForWinnersProposalNotMet();
        }
        uint48 proposalBounty = _getAuctionWinnersProposalBounty(currentAuction, _auctionId);
        // Here we check how much extra we have to give for bounty. If all the bids are minBidAmount, it means
        // we don't have any bounty to give.
        uint64 totalMinBids = uint64(_winnerBidIndexes.length) * currentAuction.minBidAmount;
        if (_totalBidAmount > totalMinBids) {
            uint48 extraFunds = uint48(_totalBidAmount - totalMinBids);
            proposalBounty = proposalBounty < extraFunds ? proposalBounty : extraFunds;
        } else {
            // No bounty for proposing winners as we haven't got extra from bids. We prioritize auctionable settling.
            proposalBounty = 0;
        }

        // Also re-calculate snuff bounty. On snuff time we didn't have data to calculate snuff bounty accurately
        // as we didn't have total bid amount.
        uint48 potentialSnuffBounty = currentAuction.snuff.potentialBounty;
        // Here we check how much extra we have to give for bounty. We also need to substract winners proposal bounty.
        if (_totalBidAmount > totalMinBids + proposalBounty) {
            uint48 extraFunds = uint48(_totalBidAmount - totalMinBids - proposalBounty);
            currentAuction.snuff.bounty = potentialSnuffBounty < extraFunds ? potentialSnuffBounty : extraFunds;
        } else {
            currentAuction.snuff.bounty = 0;
        }
        currentAuction.winnersProposal = KandilWinnersProposal({
            bounty: proposalBounty,
            totalBidAmount: _totalBidAmount,
            keccak256Hash: _hash,
            winnerCount: uint16(_winnerBidIndexes.length),
            sender: payable(msg.sender),
            timestamp: uint40(block.timestamp),
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
     * @param _winnerBidIndexesBytes Byte serialized uint16 array of winner bid indexes.
     * @param _hash keccak256 hash of the winnerBidIds.
     * @param _bidIndexToInclude Index of the bid that should have been included but wasn't. type(uint16).max if the fault
     *      is either wront totalBidAmount or some of the included bids are after snuff time
     *      and shouldn't have been included.
     */
    function challengeProposedWinners(
        uint256 _auctionId,
        bytes memory _winnerBidIndexesBytes,
        bytes32 _hash,
        uint16 _bidIndexToInclude
    ) external override nonReentrant {
        Kandil storage currentAuction = kandilAuctions[_auctionId];

        if (currentAuction.auctionState != KandilState.WinnersProposed) {
            revert CannotChallengeWinnersProposalBeforePosted();
        }

        if (
            currentAuction.winnersProposal.timestamp + currentAuction.settings.fraudChallengePeriod <
            uint40(block.timestamp)
        ) {
            revert CannotChallengeWinnersProposalAfterChallengePeriodIsOver();
        }

        uint16[] memory _winnerBidIndexes = _bytesToUInt16Arr(_winnerBidIndexesBytes);

        if (keccak256(abi.encodePacked(_winnerBidIndexesBytes)) != _hash) {
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

        // Check if bidIdToInclude is in the list.
        // When bidIdToInclude won't be used in detection, should be sent as type(uint16).max.
        if (_bidIndexToInclude != type(uint16).max && _bidIndexToInclude >= currentAuction.bids.length) {
            revert ChallengeFailedBidIdToIncludeIsNotInBidList();
        }

        // Check if bidIdToInclude is in the list of bids that is before snuff time.
        uint32 inclIndex = _bidIndexToInclude == type(uint16).max ? 0 : _bidIndexToInclude;
        KandilBid storage bidToInclude = currentAuction.bids[inclIndex];
        if (
            _bidIndexToInclude != type(uint16).max &&
            uint256(bidToInclude.timestamp) > getAuctionCandleSnuffedTime(_auctionId)
        ) {
            revert ChallengeFailedBidToIncludeIsNotBeforeSnuffTime();
        }

        KandilBidWithIndex[] memory nBids = new KandilBidWithIndex[](_winnerBidIndexes.length + 1);
        bool[] memory duplicateCheck = new bool[](currentAuction.bids.length);
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

            // Check no duplicates in proposed winner bid indexes
            if (duplicateCheck[_winnerBidIndexes[i]]) {
                return _challengeSucceeded(currentAuction, _auctionId, 2);
            }
            duplicateCheck[_winnerBidIndexes[i]] = true;

            KandilBid storage bid = currentAuction.bids[_winnerBidIndexes[i]];
            // Check if any bid in the proposal is sent after the snuff time.
            if (uint256(bid.timestamp) >= getAuctionCandleSnuffedTime(_auctionId)) {
                return _challengeSucceeded(currentAuction, _auctionId, 4);
            }

            totalBidAmount += bid.bidAmount;
            nBids[i] = KandilBidWithIndex({
                bidder: bid.bidder,
                timestamp: bid.timestamp,
                bidAmount: bid.bidAmount,
                isProcessed: bid.isProcessed,
                index: _winnerBidIndexes[i]
            });
        }

        if (totalBidAmount != currentAuction.winnersProposal.totalBidAmount) {
            return _challengeSucceeded(currentAuction, _auctionId, 6);
        }
        if (_bidIndexToInclude != type(uint16).max) {
            // Add bid to include to the list of bids and sort again. If any items order changes, the challenge will succeed.
            nBids[_winnerBidIndexes.length] = KandilBidWithIndex({
                bidder: bidToInclude.bidder,
                timestamp: bidToInclude.timestamp,
                bidAmount: bidToInclude.bidAmount,
                isProcessed: bidToInclude.isProcessed,
                index: _bidIndexToInclude
            });
        }
        // Depending on contract size, sorting functions can be either in the contract or lib.
        // Having in library have extra gas cost because of copy.
        nBids = Helpers.sortBids(nBids);
        for (uint32 i = 0; i < _winnerBidIndexes.length; i++) {
            if (nBids[i].index != _winnerBidIndexes[i]) {
                return _challengeSucceeded(currentAuction, _auctionId, 7);
            }
        }

        revert ChallengeFailedWinnerProposalIsCorrect();
    }

    /**
     * @dev Called internally from challengeProposedWinners when challenge succeeds.
     */
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
        _safeTransferETHWithFallback(
            msg.sender,
            uint256(currentAuction.settings.winnersProposalDepositAmount) * (1 gwei)
        );
    }

    /**
     * @notice This function is called by the winners list proposer to collect bounty.
     * @dev Bounty can be 0 depending on the amount of bids after snuff time. Check before calling.
     *      Can only be called after fraud proof window.
     * @param _auctionId Auction id.
     */
    function claimWinnersProposalBounty(uint256 _auctionId) external override nonReentrant {
        Kandil storage currentAuction = kandilAuctions[_auctionId];

        if (currentAuction.auctionState != KandilState.WinnersProposed) {
            revert CannotClaimWinnersProposalBountyBeforePosted();
        }

        if (msg.sender != currentAuction.winnersProposal.sender) {
            revert CannotClaimWinnersProposalBountyIfNotProposer();
        }

        if (
            currentAuction.winnersProposal.timestamp + uint40(currentAuction.settings.fraudChallengePeriod) >=
            uint40(block.timestamp)
        ) {
            revert CannotClaimWinnersProposalBountyBeforeChallengePeriodIsOver();
        }

        if (currentAuction.winnersProposal.isBountyClaimed) {
            revert WinnersProposalBountyAlreadyClaimed();
        }

        if (currentAuction.winnersProposal.bounty == 0) {
            revert WinnersProposalBountyIsZero();
        }

        uint256 bounty = uint256(
            currentAuction.winnersProposal.bounty + currentAuction.settings.winnersProposalDepositAmount
        ) * (1 gwei);

        currentAuction.winnersProposal.isBountyClaimed = true;

        _safeTransferETHWithFallback(msg.sender, bounty);

        emit WinnersProposalBountyClaimed(msg.sender, _auctionId, bounty);
    }

    /**
     * @notice This function is called by the snuffer to collect bounty.
     * @dev Bounty can be 0 depending on the amount of bids after snuff time. Check before calling.
     *      Can only be called after fraud proof window.
     * @param _auctionId Auction id.
     */
    function claimSnuffBounty(uint256 _auctionId) external override nonReentrant {
        Kandil storage currentAuction = kandilAuctions[_auctionId];

        if (currentAuction.auctionState != KandilState.WinnersProposed) {
            revert CannotClaimSnuffBountyBeforeWinnersProposed();
        }

        if (msg.sender != currentAuction.snuff.sender) {
            revert CannotClaimSnuffBountyBeforeIfNotSnuffer();
        }

        if (
            currentAuction.winnersProposal.timestamp + currentAuction.settings.fraudChallengePeriod >=
            uint40(block.timestamp)
        ) {
            revert CannotClaimSnuffBountyBeforeChallengePeriodIsOver();
        }

        if (currentAuction.snuff.isBountyClaimed) {
            revert SnuffBountyAlreadyClaimed();
        }

        if (currentAuction.snuff.bounty == 0) {
            revert SnuffBountyIsZero();
        }

        _safeTransferETHWithFallback(currentAuction.snuff.sender, uint256(currentAuction.snuff.bounty) * (1 gwei));

        emit SnuffBountyClaimed(currentAuction.snuff.sender, _auctionId, currentAuction.snuff.bounty);
    }

    /**
     * @notice This function is called by the bidder who didn't win the auction.
     *      Can only be called after fraud proof window.
     * @param _auctionId Auction id.
     * @param _bidIndex Bid index in the auction's bids array.
     * @param _hash keccak256 hash of the winnerBidIds
     * @param _winnerBidIndexesBytes Byte serialized uint16 array of winner bid indexes.
     */
    function withdrawLostBid(
        uint256 _auctionId,
        uint256 _bidIndex,
        bytes32 _hash,
        bytes calldata _winnerBidIndexesBytes
    ) external override nonReentrant {
        Kandil storage currentAuction = kandilAuctions[_auctionId];
        if (currentAuction.auctionState != KandilState.WinnersProposed) {
            revert CannotWithdrawLostBidBeforeWinnersProposed();
        }

        if (
            currentAuction.winnersProposal.timestamp + currentAuction.settings.fraudChallengePeriod >=
            uint40(block.timestamp)
        ) {
            revert CannotWithdrawLostBidBeforeChallengePeriodEnds();
        }

        uint16[] memory _winnerBidIndexes = _bytesToUInt16Arr(_winnerBidIndexesBytes);

        if (keccak256(abi.encodePacked(_winnerBidIndexesBytes)) != _hash) {
            revert WinnerProposalDataDoesntHaveCorrectHash();
        }

        if (currentAuction.winnersProposal.keccak256Hash != _hash) {
            revert WinnerProposalHashDoesntMatchPostedHash();
        }

        // If all winners already claimed no need to check, saves a lot of gas for high winner count auctions
        if (currentAuction.claimedWinnerCount != _winnerBidIndexes.length) {
            for (uint256 i = 0; i < _winnerBidIndexes.length; i++) {
                if (_bidIndex == _winnerBidIndexes[i]) {
                    revert CannotWithdrawLostBidIfIncludedInWinnersProposal();
                }
            }
        }

        KandilBid storage bid = currentAuction.bids[_bidIndex];
        if (bid.isProcessed) {
            revert CannotWithdrawAlreadyWithdrawnBid();
        }

        if (bid.bidder != msg.sender) {
            revert CannotWithdrawBidIfNotSender();
        }

        bid.isProcessed = true;

        uint256 amount = uint256(bid.bidAmount) * (1 gwei);
        _safeTransferETHWithFallback(bid.bidder, amount);

        emit LostBidWithdrawn(msg.sender, _auctionId, _bidIndex);
    }

    /**
     * @notice This function is called by the bidder who didn't win the auction.
     *      Can only be called after fraud proof window.
     * @param _auctionId Auction id.
     * @param _bidIndex Bid index in the auction's bids array.
     */
    function withdrawLostBidAfterAllWinnersClaimed(uint256 _auctionId, uint256 _bidIndex)
        external
        override
        nonReentrant
    {
        Kandil storage currentAuction = kandilAuctions[_auctionId];
        if (currentAuction.auctionState != KandilState.WinnersProposed) {
            revert CannotWithdrawLostBidBeforeWinnersProposed();
        }

        if (
            currentAuction.winnersProposal.timestamp + currentAuction.settings.fraudChallengePeriod >=
            uint40(block.timestamp)
        ) {
            revert CannotWithdrawLostBidBeforeChallengePeriodEnds();
        }

        // If all winners haven't claimed already, withdrawLostBid should be used instead
        if (currentAuction.claimedWinnerCount != currentAuction.winnersProposal.winnerCount) {
            revert CannotWithdrawUntilAllWinnersClaims();
        }

        KandilBid storage bid = currentAuction.bids[_bidIndex];
        if (bid.isProcessed) {
            revert CannotWithdrawAlreadyWithdrawnBid();
        }

        if (bid.bidder != msg.sender) {
            revert CannotWithdrawBidIfNotSender();
        }

        bid.isProcessed = true;

        uint256 amount = uint256(bid.bidAmount) * (1 gwei);
        _safeTransferETHWithFallback(bid.bidder, amount);

        emit LostBidWithdrawn(msg.sender, _auctionId, _bidIndex);
    }

    /**
     * @notice Anyone can execute to claim a token but it will be settled for the bidder
     *      and minimum bid amount will be sent to the caller of this function. This way NFT can be minted
     *      anytime by anyone at the most profitable (least congested) time.
     * @param _auctionId Auction id.
     * @param _hash keccak256 hash of the winnerBidIds
     * @param _winnerBidIndexesBytes Byte serialized uint16 array of winner bid indexes.
     * @param _winnerBidIndexesIndex Index of the _winnerBidIndexes array which in return holds index in
     * the auction bids array.
     */
    function claimWinningBid(
        uint256 _auctionId,
        bytes32 _hash,
        bytes calldata _winnerBidIndexesBytes,
        uint256 _winnerBidIndexesIndex
    ) external nonReentrant {
        Kandil storage currentAuction = kandilAuctions[_auctionId];
        uint16[] memory _winnerBidIndexes = _bytesToUInt16Arr(_winnerBidIndexesBytes);
        if (_winnerBidIndexesIndex >= _winnerBidIndexes.length) {
            revert BidIdDoesntExist();
        }
        uint32 bidIndex = _winnerBidIndexes[_winnerBidIndexesIndex];
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

        if (
            currentAuction.winnersProposal.timestamp + uint40(currentAuction.settings.fraudChallengePeriod) >=
            uint40(block.timestamp)
        ) {
            revert CannotClaimAuctionItemBeforeChallengePeriodEnds();
        }

        if (keccak256(abi.encodePacked(_winnerBidIndexesBytes)) != _hash) {
            revert WinnerProposalDataDoesntHaveCorrectHash();
        }

        if (currentAuction.winnersProposal.keccak256Hash != _hash) {
            revert WinnerProposalHashDoesntMatchPostedHash();
        }

        KandilBid storage bid = currentAuction.bids[bidIndex];
        if (bid.isProcessed) {
            revert BidAlreadyClaimed();
        }

        bid.isProcessed = true;
        currentAuction.claimedWinnerCount++;

        auctionable.settle(
            bid.bidder,
            uint256(keccak256(abi.encodePacked(currentAuction.vrfResult, bidIndex, "EnTrOpy")))
        );

        // Calculate bounty based on minBidAmount.
        _safeTransferETHWithFallback(msg.sender, uint256(currentAuction.minBidAmount) * (1 gwei));

        recordBaseFeeObservation();

        emit WinningBidClaimed(msg.sender, _auctionId, bidIndex, bid.bidder);
    }

    /**
     * @notice This function is called to transfer collected funds to owner.
     * @dev This function call is not restricted to owner to allow anyone to
     *      EOA to transfer funds to owner. Because otherwise, if the owner is a DAO,
     *      restricting will require a proposal for each auction.
     * @param _auctionId Auction id.
     */
    function transferAuctionFundsToOwner(uint256 _auctionId) external override nonReentrant {
        Kandil storage currentAuction = kandilAuctions[_auctionId];
        if (currentAuction.auctionState != KandilState.WinnersProposed) {
            revert CannotTransferFundsBeforeWinnersProposed();
        }

        if (
            currentAuction.winnersProposal.timestamp + uint40(currentAuction.settings.fraudChallengePeriod) >=
            uint40(block.timestamp)
        ) {
            revert CannotTransferFundsBeforeChallengePeriodEnds();
        }

        if (currentAuction.isFundsTransferred) {
            revert FundsAlreadyTransferred();
        }

        currentAuction.isFundsTransferred = true;

        // Calculate all bounties.
        uint256 paidBounties = (currentAuction.winnersProposal.winnerCount *
            (uint256(currentAuction.minBidAmount) * (1 gwei))) +
            (uint256(currentAuction.snuff.bounty) * (1 gwei)) +
            (uint256(currentAuction.winnersProposal.bounty) * (1 gwei));

        uint256 totalAmount = (uint256(currentAuction.winnersProposal.totalBidAmount) * (1 gwei)) - paidBounties;
        _safeTransferETHWithFallback(owner(), totalAmount);
    }

    /*
     */
    /**
     * @notice Configure kandil house to whether to require depositing LINK while calling snuff.
     * If this is false, LINK needs to be deposited to the contract externally.
     */
    /*

    function setAuctionRequiresLink(bool _requiresLink) external onlyOwner {
        settings.snuffRequiresSendingLink = _requiresLink;
    }
*/

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
        currentAuction.vrfSetTime = uint40(block.timestamp);
        currentAuction.auctionState = KandilState.VRFSet;
    }

    /**
     * @notice Probabilistic storage of base fee observations. We store each observation randomly
     * in a bucket. Use gwei as unit and limit to max uint16 (65535). I hope we'll never see such gwei anyway.
     */
    function recordBaseFeeObservation() internal {
        uint256 timeOfDay = block.timestamp % 86400;
        uint256 bucketIndex = timeOfDay / 900;
        uint16 baseFee = block.basefee < ((1 gwei) * uint256((type(uint16).max - 1)))
            ? uint16(block.basefee / (1 gwei))
            : type(uint16).max - 1;
        baseFeeObservations[bucketIndex] = baseFee;
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

    /**
     * @notice Getter for minimum bid amount of the auction.
     */
    function getAuctionMinimumBidAmount(uint256 _auctionId) external view returns (uint256) {
        Kandil storage currentAuction = kandilAuctions[_auctionId];
        return uint256(currentAuction.minBidAmount) * (1 gwei);
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

    /**
     * @notice Getter for start time of the auction.
     */
    function getAuctionStartTime(uint256 _auctionId) public view returns (uint256) {
        return uint256(kandilAuctions[_auctionId].startTime);
    }

    /**
     * @notice Getter for state of the auction.
     */
    function getAuctionState(uint256 _auctionId) public view returns (KandilState) {
        return kandilAuctions[_auctionId].auctionState;
    }

    /**
     * @notice Getter for definite end time of the auction.
     */
    function getAuctionDefiniteEndTime(uint256 _auctionId) public view returns (uint256) {
        return uint256(kandilAuctions[_auctionId].definiteEndTime);
    }

    /**
     * @notice Getter for winner proposal time of the auction.
     */
    function getAuctionWinnerProposalTime(uint256 _auctionId) public view returns (uint256) {
        return uint256(kandilAuctions[_auctionId].winnersProposal.timestamp);
    }

    /**
     * @notice Getter for vrf set time of the auction.
     */
    function getAuctionVRFSetTime(uint256 _auctionId) public view returns (uint256) {
        return uint256(kandilAuctions[_auctionId].vrfSetTime);
    }

    /**
     * @notice Getter for snuff percentage of the auction.
     */
    function getAuctionSnuffPercentage(uint256 _auctionId) external view returns (uint256) {
        return uint256(kandilAuctions[_auctionId].settings.snuffPercentage);
    }

    /**
     * @notice Getter for maximum winner number of the auction.
     */
    function getAuctionMaxWinnerCount(uint256 _auctionId) external view returns (uint256 r) {
        r = kandilAuctions[_auctionId].settings.maxWinnersPerAuction;
    }

    /**
     * @notice Getter for vrf result of the auction.
     */
    function getAuctionVRF(uint256 _auctionId) external view returns (uint256 r) {
        r = kandilAuctions[_auctionId].vrfResult;
    }

    /**
     * @notice Getter for winners proposal deposit the auction.
     */
    function getAuctionRequiredWinnersProposalDeposit(uint256 _auctionId) external view returns (uint256 r) {
        r = uint256(kandilAuctions[_auctionId].settings.winnersProposalDepositAmount) * (1 gwei);
    }

    /**
     * @notice Get the potential snuff bounty before calling the snuff. After snuff bounty could be as low as 0,
     *      due to not having enough bid amount (after snuff time) to cover snuff bounty.
     */
    function getAuctionPotentialRetroSnuffBounty(uint256 _auctionId) public view returns (uint256) {
        Kandil storage currentAuction = kandilAuctions[_auctionId];
        return _getAuctionRetroSnuffBounty(currentAuction) * (1 gwei);
    }

    /**
     * @notice Get the potential winners proposal bounty.
     */
    function getAuctionPotentialWinnersProposalBounty(uint256 _auctionId) public view returns (uint256) {
        Kandil storage currentAuction = kandilAuctions[_auctionId];
        return _getAuctionWinnersProposalBounty(currentAuction, _auctionId) * (1 gwei);
    }

    /**
     * @notice Get actual snuff bounty. Before winners proposal, this will be always 0.
     */
    function getAuctionRetroSnuffBounty(uint256 _auctionId) public view returns (uint256) {
        Kandil storage currentAuction = kandilAuctions[_auctionId];
        return uint256(currentAuction.snuff.bounty) * (1 gwei);
    }

    /**
     * @notice Get actual winners proposal bounty. Before winners proposal, this will be always 0.
     */
    function getAuctionWinnersProposalBounty(uint256 _auctionId) public view returns (uint256) {
        Kandil storage currentAuction = kandilAuctions[_auctionId];
        return uint256(currentAuction.winnersProposal.bounty) * (1 gwei);
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
        uint48 bountyBase,
        uint256 timeMultiplier,
        uint8 maxBountyMultiplier
    ) internal view returns (uint48) {
        return
            bountyBase + ((bountyBase / 10) * uint48(timeMultiplier)) > bountyBase * maxBountyMultiplier
                ? bountyBase * maxBountyMultiplier
                : bountyBase + ((bountyBase / 10) * uint48(timeMultiplier));
    }

    function _getAuctionRetroSnuffBounty(Kandil storage currentAuction) internal view returns (uint48) {
        uint256 timePassed = block.timestamp - currentAuction.definiteEndTime;
        uint256 timeMultiplier = timePassed / 12;
        uint48 bountyBase = uint48(currentAuction.settings.retroSnuffGas * currentAuction.targetBaseFee);

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

    function _getAuctionWinnersProposalBounty(Kandil storage currentAuction, uint256 _auctionId)
        internal
        view
        returns (uint48)
    {
        uint256 timePassed = block.timestamp - getAuctionVRFSetTime(_auctionId);
        uint256 timeMultiplier = timePassed / 12;
        uint48 bountyBase = (currentAuction.settings.winnersProposalGas * currentAuction.targetBaseFee);

        return _calculateBounty(bountyBase, timeMultiplier, currentAuction.settings.maxBountyMultiplier);
    }

    /**
     * @notice Here we sort observed base fees, remove top 2 and return average of next 4.
     */
    function _getTargetBaseFee() internal view returns (uint16) {
        uint16[96] memory baseFeeObservationsCopy = baseFeeObservations;
        _sortBaseFeeObservations(baseFeeObservationsCopy, 0, int256(baseFeeObservationsCopy.length - 1));
        return (baseFeeObservations[2] + baseFeeObservations[3] + baseFeeObservations[4] + baseFeeObservations[5]) / 4;
    }

    function _sortBaseFeeObservations(
        uint16[96] memory arr,
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

    function _getCurrentMinimumBidAmount() internal view returns (uint48 minBid) {
        minBid = uint48(_getTargetBaseFee() * auctionable.getGasCost());
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

    function _bytesToUInt16Arr(bytes memory _bytes) internal pure returns (uint16[] memory tempUint) {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            let length := div(mload(_bytes), 2) // get size of _bytes and divide by 2 to get uint16 arr size.
            tempUint := mload(0x40)
            mstore(add(tempUint, 0x00), length)
            let i := 0
            for {

            } lt(i, length) {
                i := add(i, 1)
            } {
                mstore(add(tempUint, add(mul(i, 0x20), 0x20)), mload(add(add(_bytes, 0x2), mul(i, 2))))
            }
            mstore(0x40, add(tempUint, add(mul(i, 0x20), 0x20)))
        }
    }

    // Sort bids first by bidAmount and for same amount, by their index. This can probably be optimized.
    // however this will be only used when a winners proposal is challenged. So sanely never...
    // Also as sorting will happen on client side for sending winners proposal. (in JS)
    /*    function sortBids(IKandilli.KandilBidWithIndex[] memory nBids)
        public
        returns (IKandilli.KandilBidWithIndex[] memory)
    {
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
        return nBids;
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
    }*/
}

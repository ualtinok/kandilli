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

    KandilHouseSettings public settings;

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
     */
    constructor(
        IAuctionable _auctionToken,
        KandilHouseSettings memory _initialSettings,
        uint32[] memory _initBaseFeeObservations,
        address _weth,
        address _linkToken,
        address _vrfCoordinator,
        uint256 _vrfFee
    ) VRFConsumerBase(_vrfCoordinator, _linkToken) {
        auctionToken = _auctionToken;
        weth = IWETH(_weth);
        settings = _initialSettings;
        baseFeeObservations = _initBaseFeeObservations;

        vrfFee = _vrfFee;
        keyHash = 0x6c3699283bda56ad74f6b855546325b68d482e983852a7a82979cc4807b641f4;
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

        emit AuctionStarted(auctionId.current(), uint64(block.timestamp));
    }

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
                isClaimed: false
            })
        );

        emit AuctionBid(_auctionId, currentAuction.bids.length - 1, msg.sender, msg.value);

        return currentAuction.bids.length - 1;
    }

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

        emit AuctionBidIncrease(_auctionId, _bidId, msg.sender, msg.value);
    }

    function postWinners(
        uint256 _auctionId,
        uint32[] calldata _winnerBidIds,
        bytes32 _hash
    ) external payable override {
        Kandil storage currentAuction = kandilAuctions[_auctionId];
        if (currentAuction.auctionState != KandilState.VRFSet) {
            revert CannotPostWinnersBeforeVRFSetOrWhenWinnersAlreadyPosted();
        }

        if (keccak256(abi.encodePacked(_winnerBidIds, currentAuction.vrfResult)) != _hash) {
            revert IncorrectHashForWinnerBids();
        }

        //TODO: Make it dynamic via percentage of the total bid amount ?
        if (msg.value != (currentAuction.settings.winnersProposalDepositAmount * (1 gwei))) {
            revert DepositAmountForWinnersProposalNotMet();
        }

        currentAuction.winnersProposal = KandilWinnersProposal({
            keccak256Hash: _hash,
            deposit: msg.value,
            sender: payable(msg.sender),
            timestamp: uint64(block.timestamp)
        });
        currentAuction.auctionState = KandilState.WinnersPosted;

        emit AuctionWinnersPosted(_auctionId, msg.sender, _hash);
    }

    /**
     * @notice Most critical function. Anyone can challenge the winners proposal by sending winner proposal data +
     *
     */
    function challengePostedWinners(
        uint256 _auctionId,
        uint32[] calldata _winnerBidIds,
        bytes32 _hash,
        uint32 _bidIdToNotInclude,
        uint32 _bidIdToInclude
    ) external {
        Kandil storage currentAuction = kandilAuctions[_auctionId];

        if (currentAuction.auctionState != KandilState.WinnersPosted || currentAuction.winnersProposal.deposit == 0) {
            revert CannotChallengeWinnersProposalBeforePosted();
        }

        if (currentAuction.winnersProposal.timestamp + currentAuction.settings.fraudChallengePeriod < uint64(block.timestamp)) {
            revert CannotChallengeWinnersProposalAfterChallengePeriodIsOver();
        }

        if (keccak256(abi.encodePacked(_winnerBidIds, currentAuction.vrfResult)) != _hash) {
            revert WinnerProposalDataDoesntHaveCorrectHash();
        }

        if (currentAuction.winnersProposal.keccak256Hash != _hash) {
            revert WinnerProposalHashDoesntMatchWinnerPostHash();
        }

        if (currentAuction.winnersProposal.sender == msg.sender) {
            revert CannotChallengeSelfProposal();
        }

        // Simply check if amount of bids can satisfy proposed winner count
        if (currentAuction.bids.length < _winnerBidIds.length) {}

        // First check if all bid ids are valid
        for (uint32 i = 0; i < _winnerBidIds.length; i++) {
            if (currentAuction.bids[_winnerBidIds[i]].bidAmount < currentAuction.minBidAmount) {}
        }
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
            revert WinnerProposalHashDoesntMatchWinnerPostHash();
        }

        if (_winnerBidIds[_winnerBidIdIndex] != _bidId) {
            revert WinnerProposalBidIdDoesntMatch();
        }

        if (currentAuction.bids[_bidId].isClaimed) {
            revert BidAlreadyClaimed();
        }

        currentAuction.bids[_bidId].isClaimed = true;

        auctionToken.settle(
            currentAuction.bids[_bidId].bidder,
            uint256(keccak256(abi.encodePacked(currentAuction.vrfResult, _bidId, "EnTrOpy")))
        );

        _safeTransferETHWithFallback(msg.sender, uint256(currentAuction.minBidAmount * (1 gwei)));

        recordBaseFeeObservation();

        emit WinningBidClaimed(_auctionId, _bidId, msg.sender, currentAuction.bids[_bidId].bidder);
    }

    /**
     * @notice This function requests Chainlink VRF for a random number. Once the VRF is called back we know the
     * auction's actual ending time. Anyone can call this function once an auction is passed the definiteEndtime
     * to collect a bounty.  The bounty periodically increases and targets initally to gas cost to call
     * this function * targetBaseFee. It also starts the next auction.
     */
    function retroSnuffCandle(uint256 _auctionId) external override nonReentrant returns (bytes32 requestId) {
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

        _safeTransferETHWithFallback(msg.sender, _getAuctionRetroSnuffBounty(currentAuction, _auctionId));

        emit VRFRequested(_auctionId, requestId);
    }

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

    function recordBaseFeeObservation() internal {
        uint256 index = block.number != 0 ? uint256(blockhash(block.number - 1)) % 10 : 0;
        baseFeeObservations[index] = uint32(block.basefee / (1 gwei));
    }

    function getAuctionMinimumBidAmount(uint256 _auctionId) external view returns (uint256 minBid) {
        Kandil storage currentAuction = kandilAuctions[_auctionId];
        minBid = uint256(currentAuction.minBidAmount * (1 gwei));
    }

    // TODO: page limit for view gas limit (10x the block gas limit in infura)
    function getAuctionBids(
        uint256 _auctionId /*,
        uint256 page,
        uint256 limit*/
    ) external view override returns (KandilBid[] memory bids) {
        Kandil storage currentAuction = kandilAuctions[_auctionId];
        return currentAuction.bids;
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

    function _getAuctionRetroSnuffBounty(Kandil storage currentAuction, uint256 _auctionId) internal view returns (uint256) {
        uint256 timePassed = block.timestamp - getAuctionDefiniteEndTime(_auctionId);
        uint256 multiplier = timePassed / 24 > currentAuction.settings.maxBountyMultiplier
            ? currentAuction.settings.maxBountyMultiplier
            : (timePassed / 24) + 1;

        return (currentAuction.settings.retroSnuffGasCost * currentAuction.targetBaseFee * multiplier) * 1 gwei;
    }

    function _getTargetBaseFee() internal view returns (uint32) {
        uint32[] memory baseFeeObservationsCopy = baseFeeObservations;
        _sortBaseFeeObservations(baseFeeObservationsCopy, 0, baseFeeObservationsCopy.length - 1);
        return (baseFeeObservations[0] + baseFeeObservations[1] + baseFeeObservations[2] + baseFeeObservations[3]) / 4;
    }

    function _sortBaseFeeObservations(
        uint32[] memory arr,
        uint256 left,
        uint256 right
    ) internal pure {
        uint256 i = left;
        uint256 j = right;
        if (i == j) return;
        uint256 pivot = arr[left + (right - left) / 2];
        while (i <= j) {
            while (arr[i] < pivot) i++;
            while (pivot < arr[j]) j--;
            if (i <= j) {
                (arr[i], arr[j]) = (arr[j], arr[i]);
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
}

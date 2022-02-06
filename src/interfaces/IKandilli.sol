// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.11;

interface IKandilli {
    // @notice Current state of the auction
    enum KandilState {
        Created,
        Running,
        WaitingVRFResult,
        VRFSet,
        WinnersPosted
    }

    // @notice Here we're using very tight packing with high gas optimization, below struct fits into a single storage slot (32 bytes)
    // For this we use timestamp as uint32 and this is set to block.timestamp - startTime
    // For bidAmount we use gwei denomination by restricting bids to not use lower than a gwei precision
    struct KandilBid {
        address payable bidder; // address of the bidder
        uint32 timePassedFromStart; // time passed from startTime
        uint64 bidAmount; // bid value in gwei
        bool isClaimed;
    }

    // Sender of the winner claims rewarded with ethers if it's not challenged and proven fraud.
    // If proven fraud, claims sender loses deposit.
    struct KandilWinnersProposal {
        bytes32 keccak256Hash;
        uint256 deposit;
        address payable sender;
        uint64 timestamp;
    }

    struct KandilHouseSettings {
        uint64 winnersProposalDepositAmount;
        uint32 fraudChallengePeriod;
        uint32 retroSnuffGasCost;
        uint32 postWinnersGasCost;
        uint32 auctionTotalDuration;
        uint32 numWinnersPerAuction;
        uint8 maxBountyMultiplier;
        uint8 snuffPercentage;
        bool snuffRequiresSendingLink;
    }

    /**
     * @notice Current state of the auction
     * @param startTime: Auction start time as 64bit timestamp
     * @param definiteEndTime: Auction end time as 64bit timestamp.  This is not the exact time when the auction ends but
     *      it depends on the VRF result which dictates the real end of auction
     * @param minBidAmount: The minimum bid amount. It should approximately follow auctionable settle gas price + %10-%15.
     * @param vrfSetTime: When VRF result returns this set to current block.timestamp
     * @param vrfResult: VRF result returned from Chainlink
     * @param requiredWinnersProposalDepositAmount: Amount deposited by the winners proposal sender.
     * @param numWinners: How many winners per auction
     * @param snuffPercentage: Percentage of candle snuff period in the total duration of auction.
     *      Ex: If the duration (definiteEndTime - startTime) is 10 days and snuffPercentage is %30 candle will get
     *      snuffed between 7 days and 10 days depending on vrfResult
     * @param bids: Sequential array of bids
     * @param auctionState: Current state of the auction
     * @param winnersProposal: Winners proposal can be send by anyone it has a fraud proof challenge period,
     *      if challenged and proven fraud, deposit is transfered to the challenger,
     *      winnersProposal set to 0 and wait for new winners proposal.
     */
    struct Kandil {
        uint256 vrfResult;
        uint64 startTime;
        uint64 minBidAmount;
        uint64 targetBaseFee;
        uint32 vrfSetTime;
        KandilHouseSettings settings;
        KandilBid[] bids;
        KandilState auctionState;
        KandilWinnersProposal winnersProposal;
    }

    /// ---------------------------
    /// ------- EVENTS  -----------
    /// ---------------------------

    event AuctionStarted(uint256 auctionId, uint64 startTime);

    event AuctionBid(uint256 auctionId, uint256 bidId, address sender, uint256 value);

    event AuctionBidIncrease(uint256 auctionId, uint256 bidId, address sender, uint256 value);

    event AuctionWinnersPosted(uint256 auctionId, address sender, bytes32 hash);

    event VRFRequested(uint256 auctionId, bytes32 requestId);

    event WinningBidClaimed(uint256 auctionId, uint256 bidId, address claimer, address claimedto);

    /// ---------------------------
    /// ------- ERRORS  -----------
    /// ---------------------------

    error BidWithPrecisionLowerThanGwei();

    error AuctionIsNotRunning();

    error CannotBidAfterAuctionEndTime();

    error MinimumBidAmountNotMet();

    error CannotIncreaseBidForNonOwnedBid();

    error CannotCreateNewAuctionBeforePreviousIsSettled();

    error CannotPostWinnersBeforeVRFSetOrWhenWinnersAlreadyPosted();

    error IncorrectHashForWinnerBids();

    error DepositAmountForWinnersProposalNotMet();

    error CannotClaimAuctionItemBeforeWinnersPosted();

    error CannotClaimAuctionItemBeforeChallengePeriodEnds();

    error WinnerProposalDataDoesntHaveCorrectHash();

    error WinnerProposalHashDoesntMatchWinnerPostHash();

    error WinnerProposalBidIdDoesntMatch();

    error BidAlreadyClaimed();

    error VRFRequestIdDoesntMatchToAnAuction();

    error HouseDontHaveEnoughLinkToAskForVRF();

    error UserDontHaveEnoughLinkToAskForVRF();

    error CannotSnuffCandleForNotRunningAuction();

    error CannotSnuffCandleBeforeDefiniteEndTime();

    error ReceiveVRFWhenNotExpecting();

    error CannotChallengeWinnersProposalBeforePosted();

    error CannotChallengeWinnersProposalAfterChallengePeriodIsOver();

    error CannotChallengeSelfProposal();

    error WinnerProposerNeedToDepositLink();

    error CannotPaySnuffCandleBounty();

    error KandilInsolvent();

    error EthTransferFailedDestOrAmountZero();

    error LinkDepositFailed();

    /// ---------------------------
    /// ------- FUNCS  -----------
    /// ---------------------------

    function init() external;

    function addBidToAuction(uint256 _auctionId) external payable returns (uint256);

    function increaseAmountOfBid(uint256 _auctionId, uint256 _bidId) external payable;

    function postWinners(
        uint256 _auctionId,
        uint32[] calldata _winnerBidIds,
        bytes32 _hash
    ) external payable;

    function claimWinningBid(
        uint256 _auctionId,
        uint256 _bidId,
        bytes32 _hash,
        uint32[] calldata _winnerBidIds,
        uint256 _winnerBidIdIndex
    ) external;

    function retroSnuffCandle(uint256 _auctionId) external returns (bytes32);

    function getAuctionBids(uint256 _auctionId) external view returns (KandilBid[] memory bids);

    function getAuctionCandleSnuffedTime(uint256 _auctionId) external view returns (uint256);

    function getAuctionStartTime(uint256 _auctionId) external view returns (uint256);

    function getAuctionDefiniteEndTime(uint256 _auctionId) external view returns (uint256);

    function getAuctionSnuffPercentage(uint256 _auctionId) external view returns (uint256);

    function getAuctionRetroSnuffBounty(uint256 _auctionId) external view returns (uint256 r);

    function getAuctionWinnerCount(uint256 _auctionId) external view returns (uint256);

    function getAuctionVRF(uint256 _auctionId) external view returns (uint256);

    function getAuctionRequiredWinnersProposalDeposit(uint256 _auctionId) external view returns (uint256);

    function getAuctionMinimumBidAmount(uint256 _auctionId) external view returns (uint256 minBid);
}

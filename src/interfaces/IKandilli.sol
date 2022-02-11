// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.11;

interface IKandilli {
    /**
     * @notice Current state of the auction.
     */
    enum KandilState {
        Created,
        Running,
        WaitingVRFResult,
        VRFSet,
        WinnersPosted
    }

    /**
     * @notice Here we're using very tight packing with high gas optimization, below struct fits into
     *      a single storage slot (32 bytes). For this we use timestamp as uint32 and
     *      this is set to block.timestamp - startTime. For bidAmount we use gwei denomination by
     *      restricting bids to not use lower than a gwei precision.
     */
    struct KandilBid {
        address payable bidder; // address of the bidder
        uint32 timePassedFromStart; // time passed from startTime
        uint64 bidAmount; // bid value in gwei
        bool isProcessed;
    }

    /**
     * @notice: KandilBid struct + index in the bids array so that we can easily sort bids
     *      and same value bids will be sorted by index.
     */
    struct KandilBidWithIndex {
        address payable bidder; // address of the bidder
        uint32 timePassedFromStart; // time passed from startTime
        uint64 bidAmount; // bid value in gwei
        bool isProcessed;
        uint32 index;
    }

    /**
     * @notice: Sender of the winners proposal rewarded with ethers if it's not challenged and proven fraud.
     *      If proven fraud, proposal sender loses deposit to challenger.
     */
    struct KandilWinnersProposal {
        uint256 reward;
        bytes32 keccak256Hash;
        uint32 winnerCount;
        address payable sender;
        uint64 timestamp;
    }

    /**
     * @notice Settings for the auction
     * @param winnersProposalDepositAmount: deposit amount in gwei for sending winners proposal.
     * @param fraudChallengePeriod: Period in seconds for which fraud challenge is active.
     * @param retroSnuffGas: Approximate gas cost of a retroSnuff call.
     * @param winnersProposalGas: Approximate gas cost of a winners proposal call.
     * @param auctionTotalDuration: Total duration in seconds. (not timestamp, this + startTime is used as end timestamp)
     * @param numWinnersPerAuction: Desired number of winners per auction.
     * @param maxBountyMultiplier: Bounty multiplier, every 12 seconds bounties increase by 0.1 base
     *      bounty up to this multiplier.
     * @param snuffPercentage: Percentage of candle snuff period in the total duration of auction.
     *      Ex: If the duration (definiteEndTime - startTime) is 10 days and snuffPercentage is %30 candle will get
     *      snuffed between 7 days and 10 days depending on vrfResult
     * @param snuffRequiresSendingLink: If true, caller of the retroSnuffCandle() must approve Link tokens for contract and should have
     *      enough Link to pay for the VRF function. (amount depends on chain, 2 Link for Ethereum mainnet)
     */
    struct KandilAuctionSettings {
        uint64 winnersProposalDepositAmount;
        uint32 fraudChallengePeriod;
        uint32 retroSnuffGas;
        uint32 winnersProposalGas;
        uint32 auctionTotalDuration;
        uint32 numWinnersPerAuction;
        uint8 maxBountyMultiplier;
        uint8 snuffPercentage;
        bool snuffRequiresSendingLink;
    }

    /**
     * @notice Current state of the auction
     * @param vrfResult: VRF result returned from Chainlink
     * @param paidSnuffReward: Amount paid to snuffer for calling VRF func.
     * @param startTime: Auction start time as 64bit timestamp
     * @param minBidAmount: The minimum bid amount. It should approximately follow auctionable settle gas price + %10-%15.
     * @param targetBaseFee: Basefee we set at the auction creation based on observed base fees during auctionable settle calls.
     * @param vrfSetTime: When VRF result returns this set to current block.timestamp as 64bit timestamp.
     * @param settings: KandilAuctionSettings struct
     * @param bids: Array of bids
     * @param auctionState: Current state of the auction
     * @param winnersProposal: Winners proposal can be send by anyone it has a fraud proof challenge period,
     *      if challenged and proven fraud, deposit is transfered to the challenger,
     *      winnersProposal set to 0 and wait for new winners proposal.
     */
    struct Kandil {
        uint256 vrfResult;
        uint256 paidSnuffReward;
        uint64 startTime;
        uint64 minBidAmount;
        uint64 targetBaseFee;
        uint32 vrfSetTime;
        KandilAuctionSettings settings;
        KandilBid[] bids;
        KandilState auctionState;
        KandilWinnersProposal winnersProposal;
    }

    /// ---------------------------
    /// ------- EVENTS  -----------
    /// ---------------------------

    event AuctionStarted(uint256 auctionId, uint256 startTime);

    event AuctionBid(address indexed sender, uint256 auctionId, uint256 bidId, uint256 value);

    event AuctionBidIncrease(address indexed sender, uint256 auctionId, uint256 bidId, uint256 value);

    event AuctionWinnersProposed(address indexed sender, uint256 auctionId, bytes32 hash);

    event VRFRequested(address indexed sender, uint256 auctionId, bytes32 requestId);

    event WinningBidClaimed(address indexed sender, uint256 auctionId, uint256 bidId, address claimedto);

    event LostBidWithdrawn(uint256 auctionId, uint256 bidId, address sender);

    event WinnersProposalRewardClaimed(uint256 auctionId, address sender, uint256 amount);

    event ChallengeSucceded(address indexed sender, uint256 auctionId, uint256 reason);

    /// ---------------------------
    /// ------- ERRORS  -----------
    /// ---------------------------

    error BidWithPrecisionLowerThanGwei();

    error AuctionIsNotRunning();

    error CannotBidAfterAuctionEndTime();

    error MinimumBidAmountNotMet();

    error CannotIncreaseBidForNonOwnedBid();

    error CannotCreateNewAuctionBeforePreviousIsSettled();

    error CannotProposeWinnersBeforeVRFSetOrWhenWinnersAlreadyPosted();

    error IncorrectHashForWinnerBids();

    error DepositAmountForWinnersProposalNotMet();

    error CannotClaimAuctionItemBeforeWinnersPosted();

    error CannotClaimAuctionItemBeforeChallengePeriodEnds();

    error WinnerProposalDataDoesntHaveCorrectHash();

    error WinnerProposalHashDoesntMatchPostedHash();

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

    error CannotClaimWinnersProposalRewardIfNotProposer();

    error CannotClaimWinnersProposalRewardBeforeChallengePeriodIsOver();

    error CannotClaimWinnersProposalRewardBeforePosted();

    error CannotWithdrawLostBidBeforeChallengePeriodEnds();

    error CannotWithdrawLostBidBeforeWinnersPosted();

    error CannotWithdrawLostBidIfIncludedInWinnersProposal();

    error CannotWithdrawAlreadyWithdrawnBid();

    error CannotWithdrawBidIfNotSender();

    error ChallengeFailedBidToIncludeIsNotBeforeSnuffTime();

    error ChallengeFailedBidIdToIncludeAlreadyInWinnerList();

    error ChallengeFailedWinnerProposalIsCorrect();

    error ChallengeFailedBidIdToIncludeIsNotInBidList();

    /// ---------------------------
    /// --- EXTERNAL METHODS  -----
    /// ---------------------------

    function init() external;

    function addBidToAuction(uint256 _auctionId) external payable returns (uint256);

    function increaseAmountOfBid(uint256 _auctionId, uint256 _bidId) external payable;

    function proposeWinners(
        uint256 _auctionId,
        uint32[] calldata _winnerBidIds,
        bytes32 _hash
    ) external payable;

    function challengeProposedWinners(
        uint256 _auctionId,
        uint32[] calldata _winnerBidIds,
        bytes32 _hash,
        uint32 _bidIdToInclude
    ) external;

    function claimWinnersProposalReward(uint256 _auctionId) external;

    function withdrawLostBid(
        uint256 _auctionId,
        uint256 _bidId,
        bytes32 hash,
        uint32[] calldata _winnerBidIds
    ) external;

    function claimWinningBid(
        uint256 _auctionId,
        uint256 _bidId,
        bytes32 _hash,
        uint32[] calldata _winnerBidIds,
        uint256 _winnerBidIdIndex
    ) external;

    function retroSnuffCandle(uint256 _auctionId) external returns (bytes32);

    function getAuctionBids(
        uint256 _auctionId,
        uint256 _page,
        uint256 _limit
    ) external view returns (KandilBid[] memory bids);

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

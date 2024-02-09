// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.13;

interface IKandilli {
    /**
     * @notice Current state of the auction.
     */
    enum KandilState {
        Created,
        Running,
        RunningExtended,
        WaitingSnuff,
        WaitingWinnersProposal,
        WinnersProposed,
        ChallengePeriod,
        Ended,
        EndedWithoutBids
    }

    /**
     * @notice Here we're using very tight packing with high gas optimization, below struct fits into
     *      a single storage slot (32 bytes). To be able to fit all data in single slot:
     *      - Instead of using uint256 timestamp, we use an uint40 timestamp
     *      - Instead of using uint256 for bidAmount we use uint48 and limit bids to gwei precision.
     * @param bidder: address of the bidder
     * @param timestamp: timestamp.
     * @param bidAmount: bid value in gwei
     */
    struct KandilBid {
        address payable bidder;
        uint40 timestamp;
        uint48 bidAmount;
        bool isProcessed;
    }

    /**
     * @notice: KandilBid struct + index in the bids array so that we can easily sort bids
     *      and same value bids will be sorted by index. Only used at challenge time and in memory.
     * @param bidder: address of the bidder
     * @param timestamp: uint40 timestamp.
     * @param bidAmount: bid value in gwei
     * @param index: index in bid array
     */
    struct KandilBidWithIndex {
        address payable bidder;
        uint40 timestamp;
        uint48 bidAmount;
        bool isProcessed;
        uint24 index;
    }

    /**
     * @notice: Sender of the winners proposal rewarded with ethers if it's not challenged and proven fraud.
     *      If proven fraud, proposal sender loses deposit to challenger.
     */
    struct KandilWinnersProposal {
        bytes32 keccak256Hash;
        address payable sender;
        uint48 bounty;
        uint40 timestamp;
        uint64 totalBidAmount;
        uint16 winnerCount;
        bool isBountyClaimed;
    }

    struct KandilSnuff {
        address payable sender;
        uint48 bounty;
        uint48 potentialBounty;
        uint40 timestamp;
        bool isBountyClaimed;
    }

    /**
     * @notice Settings for the auction
     * @param winnersProposalDepositAmount: deposit amount in gwei for sending winners proposal.
     * @param fraudChallengePeriod: Period in seconds for which fraud challenge is active.
     * @param snuffGas: Approximate gas cost of a snuff call.
     * @param winnersProposalGas: Approximate gas cost of a winners proposal call.
     * @param auctionTotalDuration: Total duration in seconds. (not timestamp, this + startTime is used as end timestamp)
     * @param maxWinnersPerAuction: Desired number of winners per auction.
     * @param maxBountyMultiplier: Bounty multiplier, every 12 seconds bounties increase by 0.1 base
     *      bounty up to this multiplier.
     * @param snuffPercentage: Percentage of candle snuff period in the total duration of auction.
     *      Ex: If the duration (definiteEndTime - startTime) is 10 days and snuffPercentage is %30 candle will get
     *      snuffed between 7 days and 10 days depending on vrfResult
     */
    struct KandilAuctionSettings {
        uint32 auctionTotalDuration;
        uint48 winnersProposalDepositAmount;
        uint32 fraudChallengePeriod;
        uint32 snuffGas;
        uint32 winnersProposalGas;
        uint16 maxWinnersPerAuction;
        uint8 maxBountyMultiplier;
        uint8 snuffPercentage;
    }

    /**
     * @notice Current state of the auction
     * @param vrfResult: VRF result returned from Chainlink
     * @param startTime: Auction start time as 40bit timestamp
     * @param minBidAmount: The minimum bid amount. It should approximately target auctionable settle gas price + %10-%15.
     * @param targetBaseFee: Basefee we set at the auction creation based on observed base fees during auctionable settle calls.
     * @param vrfSetTime: When VRF result returns this set to current block.timestamp as 40bit timestamp.
     * @param auctionState: Current state of the auction
     * @param claimedWinnerCount: Counter to keep track of number of winners claimed.
     * @param bids: Array of bids
     * @param settings: KandilAuctionSettings struct
     * @param winnersProposal: Winners proposal can be send by anyone it has a fraud proof challenge period,
     *      if challenged and proven fraud, deposit is transfered to the challenger,
     *      winnersProposal set to 0 and wait for new winners proposal.
     */
    struct Kandil {
        uint40 startTime;
        uint40 definiteEndTime;
        uint48 minBidAmount;
        uint32 targetBaseFee;
        uint32 claimedWinnerCount;
        uint32 settings;
        bool isFundsTransferred;
        KandilState auctionState;
        uint256 entropyResult;
        KandilWinnersProposal winnersProposal;
        KandilSnuff snuff;
        KandilBid[] bids;
    }

    /// ---------------------------
    /// ------- EVENTS  -----------
    /// ---------------------------

    event AuctionStarted(uint256 indexed auctionId, uint256 minBidAmount, uint256 settingsId);

    event SettingsUpdated(KandilAuctionSettings settings, uint256 settingsId);

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

    /// ---------------------------
    /// ------- ERRORS  -----------
    /// ---------------------------

    error AlreadyInitialized();

    error BidWithPrecisionLowerThanGwei();

    error MinimumBidAmountNotMet();

    error CannotIncreaseBidForNonOwnedBid();

    error CannotCreateNewAuctionBeforePreviousIsSettled();

    error IncorrectHashForWinnerBids();

    error DepositAmountForWinnersProposalNotMet();

    error WinnerProposalDataDoesntHaveCorrectHash();

    error WinnerProposalHashDoesntMatchPostedHash();

    error WinnerProposalBidIdDoesntMatch();

    error BidAlreadyClaimed();

    error KandilStateDoesntMatch();

    error CannotChallengeSelfProposal();

    error CannotPaySnuffCandleBounty();

    error KandilInsolvent();

    error EthTransferFailedDestOrAmountZero();

    error CannotClaimWinnersProposalBountyIfNotProposer();

    error CannotWithdrawLostBidIfIncludedInWinnersProposal();

    error CannotWithdrawAlreadyWithdrawnBid();

    error CannotWithdrawBidIfNotSender();

    error ChallengeFailedBidToIncludeIsNotBeforeSnuffTime();

    error ChallengeFailedBidIdToIncludeAlreadyInWinnerList();

    error ChallengeFailedWinnerProposalIsCorrect();

    error ChallengeFailedBidIdToIncludeIsNotInBidList();

    error FundsAlreadyTransferred();

    error BidIdDoesntExist();

    error CannotClaimSnuffBountyBeforeIfNotSnuffer();

    error WinnersProposalBountyAlreadyClaimed();

    error WinnersProposalBountyIsZero();

    error SnuffBountyAlreadyClaimed();

    error SnuffBountyIsZero();

    error CannotWithdrawUntilAllWinnersClaims();

    /// ---------------------------
    /// --- EXTERNAL METHODS  -----
    /// ---------------------------

    function init(KandilAuctionSettings memory _settings) external;

    function reset(KandilAuctionSettings memory _settings) external;

    function addBidToAuction(uint256 _auctionId) external payable returns (uint256);

    function increaseAmountOfBid(uint256 _auctionId, uint256 _bidId) external payable;

    function proposeWinners(
        uint256 _auctionId,
        bytes memory _winnerBidIndexesBytes,
        bytes32 _hash,
        uint64 _totalBidAmount
    ) external payable;

    function challengeProposedWinners(
        uint256 _auctionId,
        bytes memory _winnerBidIndexesBytes,
        bytes32 _hash,
        uint24 _bidIndexToInclude
    ) external;

    function claimWinnersProposalBounty(uint256 _auctionId) external;

    function claimSnuffBounty(uint256 _auctionId) external;

    function withdrawLostBid(uint256 _auctionId, uint256 _bidIndex, bytes32 hash, bytes memory _winnerBidIndexesBytes)
        external;

    function withdrawLostBidAfterAllWinnersClaimed(uint256 _auctionId, uint256 _bidIndex) external;

    function claimWinningBid(
        uint256 _auctionId,
        bytes32 _hash,
        bytes memory _winnerBidIndexesBytes,
        uint256 _winnerBidIdIndex
    ) external;

    function snuffCandle(uint256 _auctionId) external;

    function transferAuctionFundsToOwner(uint256 _auctionId) external;

    function getAuctionBids(uint256 _auctionId, uint256 _page, uint256 _limit)
        external
        view
        returns (KandilBid[] memory bids);

    function getAuctionCandleSnuffedTime(uint256 _auctionId) external view returns (uint256);

    function getAuctionStartTime(uint256 _auctionId) external view returns (uint256);

    function getAuctionDefiniteEndTime(uint256 _auctionId) external view returns (uint256);

    function getAuctionSnuffPercentage(uint256 _auctionId) external view returns (uint256);

    function getAuctionSnuffBounty(uint256 _auctionId) external view returns (uint256 r);

    function getAuctionMaxWinnerCount(uint256 _auctionId) external view returns (uint256);

    function getAuctionRequiredWinnersProposalDeposit(uint256 _auctionId) external view returns (uint256);

    function getAuctionMinimumBidAmount(uint256 _auctionId) external view returns (uint256 minBid);
}

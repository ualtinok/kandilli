### !!! Untested - DO NOT USE IN PRODUCTION !!!

#[WIP]Kandilli - Optimistic Candle Auctions

Kandilli is an optimistic candle auction house that is optimized for gas usage. 
Candle auction is a type of auction where bidders doesn't know exact end time of 
the auction but they know time scope of the auction. (start and definite end time).
https://en.wikipedia.org/wiki/Candle_auction

For achieving very low gas for bidding process, we use optimistic strategy in which at the end of auction
and after the candle is snuffed (meaning the actual end time of auction is known), anyone can propose the 
winner list of the auction. A deposit also will be sent by proposer. During the fraud proof window, anyone can
challenge the proposal and if the proposal has any error, proposer loses the deposit to challenger and auction 
waits for another proposal. 

This way bidding, increasing bids, withdrawing lost bids and claiming winning auction items are all very gas efficient.
- Adding bid: less than **50k** gas
- Increasing bid: less than **26k** gas
- Withdrawing lost bid: around **50k** gas
- Claiming depends on the underlying auctionable item

## Auction Process
Suppose we have a **3 day duration** auction starting at **Monday 00:00:00** and ending at **Thursday 00:00:00**. Also candle snuff percentage is set to **30%**.
So candle will be snuffed sometime in last 30% of the auction duration. In this example the actual end time will be sometime between **Wednesday 00:02:24** and **Thursday 00:00:00**.

### Step 0: Auction starts
### Step 1: Bid collection
- Anyone can bid on the auction, can have multiple different bids. 
- Anyone can increase their bids but that also resets the bidding time.
- Minimum bid amount is set to around the gas cost of the claiming of auctioned item. (see target minimum bid amount)
- Bids during the last 30% of the auction duration, could be discarded if candle snuff time is before the bid time.
- Bids cannot be withdrawn

### Step 2: Candle Snuff
- Just after Thursday 00:00:00, anyone can call the snuff function. 
- Caller of the function will receive a bounty which increases over time up to a max after the auction end time reached. This bounty is not immediately paid because depending on snuff time, auction may not have enough bids to cover the snuff bounty.
- Snuff function will ask Chainlink VRF to send back a random number. 
- Depending on setting, snuffer may need to have LINK tokens and approve token usage to the contract. 
- The next auction also starts.
### Step 3: Chainlink VRF returns
- When chainlink calls the callback function with a random number, we now know the exact end time of the auction. 

### Step 4: Winners Proposal
- Once the candle is snuffed at Step 3, anyone can send the winners proposal.
- Proposer will also deposit a set amount of ether to the contract. 
- As we now have data about the total amount of auction bids, we also set bounties for snuff and winners proposal.
### Step 5: Challenge Period
- After winners proposal is sent, we wait for a period of time before the winners are finalized. (fraud proof window)
- During this period, anyone can challenge the proposal. If challenge is successful, deposit is paid to challenger and auction 
goes back to Step 4 waiting for a new winners proposal.

### Step 6: Auction Ends
- If the winners proposal is not challenged during fraud proof window, auction ends.
- Loser bid owners, can withdraw their bids.
- Anyone can call the claim function for winners including winners themselves. See below for more details.

## About Minimum Bid Amount and "Mint for me"

Auctionable item, for example an ERC729 token contract implements IAuctionable which has 2 functions that must be overriden.
```
function settle(address to, uint256 entropy) external;

function getGasCost() external view returns (uint32);
```
When we start a new auction, we try to estimate the gas cost of the settle function by using getGasCost which returns
how much gas settle function uses and multiply that with our basefee estimate. We are using basefee observations from the previous auction for estimation. The reason we're doing 
this is to increase UX of the auction process. For example, for an NFT auction, minimum bid amount will be around minting gas cost for the NFT token. 

Once the claim function is called, we pay the caller the minimum bid amount but settle for the winner of the bid. 
So this way winner doesn't even have to mint the token as bots will call the function when it's profitable to do so. 
Winners will receive their NFTs automagically! 


## What's with the name? Kandilli?
Kandil is derived from candēla (latin for "candle"). Kandilli is a neighbourhood name in Istanbul which is famous for its observatory and earthquake research institute.

*** **cringe alert** *** this auction house will measure the earthquake that our next project will havoc. *** **end cring alert** ***

## Feature extensions:
- [ ] Lifetime limit for auctioned item count.
- [ ] Dynamic auction item count mechanism. (min/max) items per auction. Change based on previous auction sales.
- [ ] Optional basic snuff mechanism using block.difficulty instead of VRF. (more relevant after the merge as block.difficulty becomes mixHash)


## Development

First install foundry: https://onbjerg.github.io/foundry-book/getting-started/installation.html 

### Set up
```
git clone https://github.com/ualtinok/kandilli
git submodule update --init --recursive ## install dependencies
forge build
```

### Test

```
forge test
```

### Lint
```
npm install 
npm run lint 
```

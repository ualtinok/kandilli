### !!! Untested - DO NOT USE IN PRODUCTION !!!

#[WIP]Kandilli - Optimistic Candle Auctions

## What

## Why

## How



# Feature extensions:
- [ ] Lifetime limit for number auctioned items.
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

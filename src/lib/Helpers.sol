pragma solidity ^0.8.11;

import {IKandilli} from "../interfaces/IKandilli.sol";
import "../interfaces/IKandilli.sol";
import {console} from "../test/utils/Console.sol";

library Helpers {
    function checkDuplicates(uint32[] memory ids) internal returns (bool) {
        int32[] memory alreadySeenItems = new int32[](ids.length);
        // Have to fill with -1 cause evm default is 0. Any better ways???
        for (uint256 i = 0; i < ids.length; i++) {
            alreadySeenItems[i] = -1;
        }
        for (uint256 i = 0; i < ids.length; i++) {
            for (uint256 j = 0; j < alreadySeenItems.length; j++) {
                if (alreadySeenItems[j] != -1 && uint32(alreadySeenItems[j]) == ids[i]) {
                    return true;
                }
            }
            alreadySeenItems[i] = int32(ids[i]);
        }
        return false;
    }

    // Sort bids first by bidAmount and for same amount, by their index. This can probably be optimized.
    // however this will be only used when a winners proposal is challenged. So sanely never...
    // Also as sorting will happen on client side for sending winners proposal. (in JS)
    function sortBids(IKandilli.KandilBidWithIndex[] memory nBids) public returns (IKandilli.KandilBidWithIndex[] memory) {
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
    }
}

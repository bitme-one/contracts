// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.7;
pragma abicoder v2;

library ArrayHelper {
    struct Inner {
        address[] array;
        mapping(address => uint256) indexes;
    }

    event Log(uint256 i);

    function add(Inner storage self, address addr)
        internal
        returns (uint256 index)
    {
        if (self.indexes[addr] == 0) {
            self.array.push(addr);
            index = self.indexes[addr] = self.array.length;
        }

        return 0;
    }

    function getIndex(Inner storage self, address addr)
        internal
        view
        returns (uint256)
    {
        require(self.indexes[addr] > 0, "not exists");
        return self.indexes[addr] - 1;
    }

    function getByIndex(Inner storage self, uint256 index)
        internal
        view
        returns (address)
    {
        require(index < self.array.length, "index too large");
        return self.array[index];
    }

    function remove(Inner storage self, address addr) internal {
        uint256 index = getIndex(self, addr);
        emit Log(index);

        // only one item, no need to swap index.
        address affectedAddr = self.array[self.array.length - 1];
        if (self.array.length > 1) {
            self.indexes[affectedAddr] = index + 1;
            self.array[index] = affectedAddr;
        }

        self.array.pop();
        delete self.indexes[addr];
    }

    function length(Inner storage self) internal view returns (uint256) {
        return self.array.length;
    }
}

pragma solidity ^0.5.16;

import "./Owned.sol";
import "./AddressResolver.sol";


contract MixinResolver is Owned {
    AddressResolver public resolver;

    constructor(address _resolver) internal {
         require(owner != address(0), "Owner must be set");
        resolver = AddressResolver(_resolver);
    }

    /* ========== SETTERS ========== */

    function setResolver(AddressResolver _resolver) external onlyOwner {
        resolver = _resolver;
    }
}
